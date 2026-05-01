import Foundation

enum FrameEmbeddedApp {
    static let mainLua = #"""
local APP_VERSION = "2026.04.30.26"

local CAPTION_LINE_LIMIT = 30
local CAPTION_LINE_HISTORY = 50
local BATTERY_CHECK_INTERVAL = 60   -- seconds between cheap level reads
local BATTERY_FORCE_INTERVAL = 600  -- seconds between forced re-emits
local IDLE_DEEP_SLEEP = 300         -- seconds of true silence before frame.sleep()
local ACCUM_TIMEOUT = 10            -- seconds before a stranded chunk slot is dropped
local FULL_GC_INTERVAL = 5          -- seconds between forced full collections
local DISPLAY_LINE_HEIGHT = 45      -- pixels per rendered text row
local DISPLAY_TOP_OFFSET = 60       -- Y of first content row (clears mic indicator)
local DISPLAY_BOTTOM_LIMIT = 400    -- Frame OLED is 640x400
local DISPLAY_MAX_LINES = 7         -- floor((400 - 60) / 45) = 7 visible rows
local SCROLL_LINE_INTERVAL = 3    -- seconds per line of auto-scroll catch-up

-- Flag bytes for the chunked downlink protocol. iOS sends every command as
-- [0x01][flag][size_hi][size_lo][payload...] for the first chunk and
-- [0x01][flag][payload...] for continuations. Frame firmware strips the 0x01,
-- so byte 1 in `on_packet` is always the flag. Each flag has its own
-- accumulator slot, so a stranded message of one type can't block another.
local FLAG_PING            = 0x40
local FLAG_SET_PREFS       = 0x41
local FLAG_SYNC_STATE      = 0x42
local FLAG_SHOW_CAPTION    = 0x43
local FLAG_SHOW_SUGGESTION = 0x44
local FLAG_CLEAR_CAPTION   = 0x45
local FLAG_RESET           = 0x46
local FLAG_ADMIN_PROBE     = 0x47   -- v.24: on-demand SYS_PROBE for diagnostics

-- Forward declaration so handle_command can reference start_mic on SYNC_STATE / RESET
local start_mic

local state = {
  status = "idle",
  listening = false,
  brightness = 2,
  partials = true,
  needs_render = true,
  suggestion_phonetic = "",
  suggestion_english = "",
  caption_lines = {},
  caption_buffer = "",
  last_caption_text = "",
  live_partial = "",
  last_battery_check_at = 0,
  last_battery_emit_at = 0,
  last_battery_level = -1,
  last_message_at = 0,
  disconnected = false,
  scroll_offset = 0,        -- top-of-window line index (0 = no scroll)
  last_scroll_at = 0,       -- timestamp of the last auto-scroll step
  scroll_resume_at = 0,     -- 0 = no scroll pending; else absolute time (s) for the next step
}

frame.display.text("HUDini", 220, 116, { color = "WHITE", spacing = 4 })
frame.display.text("Loading...", 210, 154, { color = "LIGHTGREEN", spacing = 4 })
frame.display.show()

-- Truncates an error/traceback to a BLE-friendly size. Used by the
-- inner pcall handlers (RENDER_ERROR / AUDIO_ERROR) to bound the
-- payload of error EVTs.
local function crash_text(err)
  local text = tostring(err or "unknown error")
  if string.len(text) > 240 then
    text = string.sub(text, 1, 240)
  end
  return text
end

local function split_text(text, separator)
  local result = {}
  local start = 1
  while true do
    local found_start, found_end = string.find(text, separator, start, true)
    if found_start == nil then
      table.insert(result, string.sub(text, start))
      return result
    end
    table.insert(result, string.sub(text, start, found_start - 1))
    start = found_end + 1
  end
end

local function trim(text)
  return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

local function normalize_display_text(text)
  if text == nil then
    return ""
  end
  local normalized = tostring(text)
  normalized = string.gsub(normalized, "[\r\n\t]", " ")
  normalized = string.gsub(normalized, "%s+", " ")
  return trim(normalized)
end

-- Bounded BLE send with retry. Returns true if delivered, false if the
-- queue stayed full for the entire budget. Audio drops on overflow are
-- recoverable (lossy stream); event drops are not (handshake breaks).
-- Note: `frame.bluetooth.send` can both throw on a full TX queue AND
-- return `false` on internal backpressure. `pcall` only catches the
-- throw, so we explicitly check the return value too — without this, a
-- false return looks like success and the packet is silently dropped.
local function ble_send(payload, max_attempts)
  for _ = 1, max_attempts do
    local ok, result = pcall(frame.bluetooth.send, payload)
    if ok and result ~= false then
      return true
    end
    frame.sleep(0.001)
  end
  return false
end

local function send_event(parts)
  -- 200 attempts × 1 ms = up to 200 ms blocking. Events MUST reach iOS
  -- (handshake / status / EVT replies). Audio uses a much smaller budget
  -- (see send_data) so it can't starve events of TX bandwidth.
  ble_send(table.concat(parts, "\t"), 200)
end

-- Diagnostic: emit current Lua heap usage (KB) tagged with a label.
-- Used to pinpoint where free heap drops below the size needed by the
-- next allocation. Cheap (single send_event) and only called at known
-- transition points, not in hot loops. Avoids string.format because
-- format allocates a temporary buffer — when called from inside the
-- AUDIO_ERROR catch (which fires *because* of an allocation failure),
-- string.format is itself liable to fail. tostring on an integer is
-- the safest formatter we have.
local function send_heap(label)
  local kb = 0
  local ok, value = pcall(collectgarbage, "count")
  if ok and type(value) == "number" then kb = value end
  -- Number formatted as integer-hundredths of KB (e.g. 5023 = 50.23 KB).
  -- Reader divides by 100. Keeps the formatter allocation-free.
  send_event({ "EVT", "HEAP", label, tostring(math.floor(kb * 100 + 0.5)) })
end

-- Heap-fragmentation probe. `collectgarbage("count")` only reports total
-- bytes used — it can't tell us whether free memory is one contiguous
-- chunk or scattered crumbs. mic.read internally allocates ~33 KB
-- contiguous; if the heap is fragmented, that allocation fails even
-- when total used (~82 KB out of Frame's heap budget) leaves "plenty"
-- free in aggregate.
--
-- This probe attempts increasing-size string.rep allocations and
-- reports the largest one that succeeded. Run immediately before
-- mic.read; if largest_ok < 33 KB, the OOM is fragmentation. If
-- largest_ok >= 33 KB and mic.read still fails, the OOM is
-- firmware-side (audio DMA / mic ring buffer).
--
-- Costs a brief alloc-and-free at probe time (collected immediately).
-- Sizes in bytes; emitted as KB for readability.
local PROBE_SIZES = { 1024, 4096, 8192, 16384, 24576, 32768, 40960, 49152 }
local function probe_largest_alloc(label)
  local last_ok = 0
  for _, sz in ipairs(PROBE_SIZES) do
    local ok, s = pcall(string.rep, "x", sz)
    if ok and type(s) == "string" and string.len(s) == sz then
      last_ok = sz
      s = nil
    else
      break
    end
  end
  collectgarbage("collect")
  -- Format: EVT HEAP_PROBE <label> <largest_kb*10> (so 256 = 25.6 KB).
  -- NOTE: This probes the LUA HEAP, not the firmware system C heap.
  -- The "not enough memory" error from frame.microphone.read comes from
  -- malloc() failing in the firmware C heap (see frame-codebase
  -- source/application/lua_libraries/microphone.c). probe_system_heap
  -- below is what tests the actual failing allocator.
  send_event({ "EVT", "HEAP_PROBE", label, tostring(math.floor(last_ok / 102.4 + 0.5)) })
  return last_ok
end

-- Firmware C heap probe via mic.read itself. mic.read(N) calls malloc(N)
-- in the firmware (microphone.c lua_microphone_read), which is the same
-- allocator that fails with "not enough memory". By calling mic.read
-- with progressively smaller N when the main read fails, we can
-- deterministically classify the failure:
--   all sizes ERR  → C heap exhausted (likely a leak)
--   small OK / data, large ERR → C heap fragmented
--   all sizes return NIL or EMPTY → PDM not delivering samples (stuck)
-- Outcomes: "OK:<bytes>" / "EMPTY" / "NIL" / "ERR:<msg>".
-- Also emits BLE_STATE so we can correlate failures with disconnects.
local SYS_PROBE_SIZES = { 4, 16, 64, 128, 240, 1024, 4096 }
local function probe_system_heap(label)
  local conn_ok, conn = pcall(frame.bluetooth.is_connected)
  send_event({ "EVT", "BLE_STATE", label, (conn_ok and conn) and "1" or "0" })
  for _, sz in ipairs(SYS_PROBE_SIZES) do
    local ok, result = pcall(frame.microphone.read, sz)
    local outcome
    if not ok then
      outcome = "ERR:" .. crash_text(result)
    elseif result == nil then
      outcome = "NIL"
    elseif result == "" then
      outcome = "EMPTY"
    else
      outcome = "OK:" .. tostring(string.len(result))
    end
    send_event({ "EVT", "SYS_PROBE", label, tostring(sz), outcome })
  end
end

local function now_seconds()
  local ok, value = pcall(frame.time.utc)
  if ok and type(value) == "number" then
    return value
  end
  return 0
end

-- Per-flag chunking accumulator. Wire format (after Frame firmware strips
-- the 0x01 data prefix):
--   first chunk    = [flag][size_hi][size_lo][payload bytes...]
--   continuation   = [flag][payload bytes...]
-- `accum_by_flag[flag]` holds the in-progress slot for one message type;
-- completed payloads append to `ready_queue` in arrival order so a burst
-- of same-flag packets (e.g. PING storm) all dispatch instead of
-- overwriting one another. Modeled on Brilliant Labs' reference at
-- CitizenOneX/frame_msg/lib/lua/data.lua, with a queue tail to handle
-- rapid same-flag bursts.
local accum_by_flag = {}
local ready_queue = {}

local function on_packet(packet)
  pcall(function()
    local len = string.len(packet)
    if len < 1 then return end
    local flag = string.byte(packet, 1)
    local item = accum_by_flag[flag]
    if item == nil then
      -- New first chunk. Need at least [flag][size_hi][size_lo] = 3 bytes.
      if len < 3 then return end
      item = {
        chunks = {},
        num = 1,
        size = (string.byte(packet, 2) << 8) | string.byte(packet, 3),
        recv = len - 3,
        started_at = now_seconds(),
      }
      item.chunks[1] = string.sub(packet, 4)
      accum_by_flag[flag] = item
    else
      item.num = item.num + 1
      item.chunks[item.num] = string.sub(packet, 2)
      item.recv = item.recv + len - 1
    end
    -- Completion: receive count caught up to declared size. Note that
    -- size == 0 is a legitimate "empty payload" command (PING / RESET /
    -- CLEAR_CAPTION) and must dispatch on the same packet that opened it.
    if item.recv >= item.size then
      table.insert(ready_queue, { flag = flag, payload = table.concat(item.chunks) })
      accum_by_flag[flag] = nil
    end
  end)
end

local function read_battery_level()
  local ok, value = pcall(frame.battery_level)
  if not ok or type(value) ~= "number" then
    return nil
  end
  if value < 0 then value = 0 end
  if value > 100 then value = 100 end
  return math.floor(value + 0.5)
end

local function maybe_emit_battery(force)
  if not force then
    local ok_conn, conn = pcall(frame.bluetooth.is_connected)
    if not ok_conn or not conn then return end
  end
  local now = now_seconds()
  if not force and (now - state.last_battery_check_at) < BATTERY_CHECK_INTERVAL then
    return
  end
  state.last_battery_check_at = now
  local level = read_battery_level()
  if level == nil then return end
  local changed = level ~= state.last_battery_level
  local stale = (now - state.last_battery_emit_at) >= BATTERY_FORCE_INTERVAL
  if not (force or changed or stale) then return end
  state.last_battery_level = level
  state.last_battery_emit_at = now
  send_event({ "EVT", "BATTERY", tostring(level) })
end

local function wrap_lines(text, limit, max_lines)
  local lines = {}
  local current = ""
  local truncated = false

  text = normalize_display_text(text)
  if text == "" then
    return lines
  end

  local words = split_text(text, " ")
  for _, raw_word in ipairs(words) do
    local word = raw_word

    while string.len(word) > limit do
      if current ~= "" then
        table.insert(lines, current)
        current = ""
        if #lines >= max_lines then
          truncated = true
          break
        end
      end
      table.insert(lines, string.sub(word, 1, limit - 1) .. "-")
      word = string.sub(word, limit)
      if #lines >= max_lines then
        truncated = true
        break
      end
    end

    if truncated then
      break
    end

    if word == "" then
      break
    end

    local candidate = word
    if current ~= "" then
      candidate = current .. " " .. word
    end

    if string.len(candidate) <= limit then
      current = candidate
    else
      if current ~= "" then
        table.insert(lines, current)
        if #lines >= max_lines then
          truncated = true
          break
        end
      end
      current = word
    end
  end

  if current ~= "" and #lines < max_lines then
    table.insert(lines, current)
  elseif current ~= "" then
    truncated = true
  end

  if truncated and #lines > 0 then
    local last = lines[#lines]
    if string.len(last) > limit - 3 then
      last = string.sub(last, 1, limit - 3)
    end
    lines[#lines] = last .. "..."
  end

  return lines
end

local function draw_multiline(text, x, y, color, max_chars, max_lines)
  local lines = wrap_lines(text, max_chars, max_lines)
  local line_y = y
  for _, line in ipairs(lines) do
    frame.display.text(line, x, line_y, { color = color, spacing = 4 })
    line_y = line_y + 45
  end
  return line_y
end

local function reset_caption_buffer()
  state.caption_lines = {}
  state.caption_buffer = ""
  state.last_caption_text = ""
  state.live_partial = ""
end

local function emit_lines_from_buffer()
  while string.len(state.caption_buffer) > CAPTION_LINE_LIMIT do
    local window = string.sub(state.caption_buffer, 1, CAPTION_LINE_LIMIT)
    local space_pos = nil
    for i = CAPTION_LINE_LIMIT, 1, -1 do
      if string.sub(window, i, i) == " " then
        space_pos = i
        break
      end
    end
    if space_pos == nil then
      table.insert(state.caption_lines, string.sub(state.caption_buffer, 1, CAPTION_LINE_LIMIT - 1) .. "-")
      state.caption_buffer = string.sub(state.caption_buffer, CAPTION_LINE_LIMIT)
    else
      table.insert(state.caption_lines, string.sub(state.caption_buffer, 1, space_pos - 1))
      state.caption_buffer = string.sub(state.caption_buffer, space_pos + 1)
    end
    while #state.caption_lines > CAPTION_LINE_HISTORY do
      table.remove(state.caption_lines, 1)
    end
  end
end

local function flush_caption_text(text, is_partial)
  text = normalize_display_text(text)
  if is_partial then
    if state.partials then
      state.live_partial = text
    else
      state.live_partial = ""
    end
    return
  end

  state.live_partial = ""
  if text == "" then
    return
  end

  local last = state.last_caption_text
  if last ~= "" and string.sub(text, 1, string.len(last)) == last then
    local delta = string.sub(text, string.len(last) + 1)
    if delta ~= "" then
      state.caption_buffer = state.caption_buffer .. delta
    end
  else
    state.caption_lines = {}
    state.caption_buffer = text
  end
  state.last_caption_text = text
  emit_lines_from_buffer()
end

-- Blank the framebuffer without using power_save. Drawing a single space at
-- (1,1) and showing leaves the rest of the OLED dark. This matches Noa's
-- approach and avoids the stuck-display-on-wake bug from power_save(true).
local function blank_display()
  pcall(frame.display.text, " ", 1, 1)
  pcall(frame.display.show)
end

-- Layout (Frame display 640x400, 45 px line pitch, 60 px top offset = 7
-- usable rows):
--   Y 12          mic indicator (left) + status indicator (right)
--   Y 60+         transcription history (SKYBLUE), then live partial
--                 (SKYBLUE), then suggestion english (WHITE), then
--                 suggestion phonetic (YELLOW), all packed contiguously.
-- No region has a hard line cap; everything is wrapped to CAPTION_LINE_LIMIT
-- chars and stacked. If the combined content exceeds DISPLAY_MAX_LINES
-- rows, `state.scroll_offset` advances one row every SCROLL_LINE_INTERVAL
-- seconds until the most recent line lands at the bottom of the screen.
-- This is line-discrete (not pixel-smooth) so the OLED only flushes a few
-- times per second during catch-up — keeps the main loop unblocked.
local function build_render_lines()
  local lines = {}

  for _, l in ipairs(state.caption_lines) do
    table.insert(lines, { text = l, color = "SKYBLUE" })
  end

  local active_text = ""
  if state.live_partial ~= "" then
    active_text = state.live_partial
  elseif state.caption_buffer ~= "" then
    active_text = state.caption_buffer
  end
  if active_text ~= "" then
    for _, l in ipairs(wrap_lines(active_text, CAPTION_LINE_LIMIT, 99)) do
      table.insert(lines, { text = l, color = "SKYBLUE" })
    end
  end

  if state.suggestion_phonetic ~= "" then
    for _, l in ipairs(wrap_lines(state.suggestion_phonetic, CAPTION_LINE_LIMIT, 99)) do
      table.insert(lines, { text = l, color = "YELLOW" })
    end
  end
  if state.suggestion_english ~= "" then
    for _, l in ipairs(wrap_lines(state.suggestion_english, CAPTION_LINE_LIMIT, 99)) do
      table.insert(lines, { text = l, color = "WHITE" })
    end
  end

  return lines
end

local function render_ui()
  if not state.needs_render then return end
  state.needs_render = false

  local lines = build_render_lines()
  local total = #lines
  local target_offset = math.max(0, total - DISPLAY_MAX_LINES)
  local now = now_seconds()

  -- Content shrank? Snap up immediately so we're not stranded mid-scroll.
  if state.scroll_offset > target_offset then
    state.scroll_offset = target_offset
  end

  -- If content overflows and we haven't reached the bottom yet, advance
  -- one row and schedule the next step. The main loop is responsible for
  -- waking us back up at `scroll_resume_at` — render_ui itself does NOT
  -- get re-entered while waiting between steps. Without this, we'd
  -- rebuild the lines table 200×/sec during scroll catch-up and
  -- exhaust the Lua heap.
  if state.scroll_offset < target_offset then
    state.scroll_offset = state.scroll_offset + 1
    state.last_scroll_at = now
    if state.scroll_offset < target_offset and now > 0 then
      state.scroll_resume_at = now + SCROLL_LINE_INTERVAL
    else
      state.scroll_resume_at = 0
    end
  else
    state.scroll_resume_at = 0
  end

  pcall(frame.display.set_brightness, state.brightness)

  frame.display.text("Mic:", 24, 12, { color = "WHITE", spacing = 2 })
  frame.display.text(state.listening and "ON" or "OFF", 98, 12,
    { color = state.listening and "GREEN" or "RED", spacing = 2 })

  if state.disconnected then
    frame.display.text("disconnected", 380, 12, { color = "RED", spacing = 2 })
  end

  local first_idx = state.scroll_offset + 1
  local last_idx = math.min(total, state.scroll_offset + DISPLAY_MAX_LINES)
  local y = DISPLAY_TOP_OFFSET
  for i = first_idx, last_idx do
    frame.display.text(lines[i].text, 24, y, { color = lines[i].color, spacing = 4 })
    y = y + DISPLAY_LINE_HEIGHT
  end

  frame.display.show()
end

local function handle_command(flag, payload)
  state.last_message_at = now_seconds()
  -- Reconnect from a disconnected state IS a visible change (the
  -- "disconnected" pill goes away). Other commands set `needs_render`
  -- only when their work actually changes pixels on screen — that way
  -- routine commands like PING / SET_PREFS don't trigger a 50–150 ms
  -- OLED flush that blocks the main loop.
  if state.disconnected then
    state.disconnected = false
    state.needs_render = true
  end

  if flag == FLAG_PING then
    -- PING is iOS's reconnect bootstrap signal. v.22: we no longer touch
    -- the mic on reconnect — the mic stays running continuously from
    -- boot, and the firmware C heap stays stable as long as we don't
    -- cycle mic.start/mic.stop. We still wipe the chunked-message
    -- accumulator so any stranded partial messages from before the BLE
    -- drop don't poison the next SET_PREFS / SYNC_STATE / SHOW_CAPTION.
    accum_by_flag = {}
    ready_queue = {}
    state.listening = false
    send_event({ "EVT", "READY", frame.FIRMWARE_VERSION, tostring(frame.bluetooth.max_length()), APP_VERSION })
    return
  end

  if flag == FLAG_SYNC_STATE then
    local parts = split_text(payload, "\t")
    local was_listening = state.listening
    state.listening = parts[1] == "1"
    state.status = parts[2] or (state.listening and "listening" or "idle")
    send_event({ "EVT", "STATUS", state.status })
    -- v.22: mic stays running continuously after the boot-time start_mic.
    -- v.21 probe data proved Lua heap is identical between successful and
    -- failing mic.read attempts; the OOM lives in the firmware C heap and
    -- is caused by mic.start/mic.stop cycling fragmenting the audio DMA
    -- pool. noa's reference app starts the mic once and never stops it.
    -- We toggle ONLY whether the bytes get forwarded to iOS, not whether
    -- the mic is running.
    if state.listening and not was_listening then
      state.suggestion_phonetic = ""
      state.suggestion_english = ""
      reset_caption_buffer()
      state.scroll_offset = 0
      state.needs_render = true
    elseif was_listening and not state.listening then
      state.needs_render = true
    end
    return
  end

  if flag == FLAG_SET_PREFS then
    -- Reconnect mic-reset moved to FLAG_PING (v.20) — PING arrives first
    -- on every (re)connect and is a 1-byte message that can't get
    -- swallowed by stale chunked-accumulator state, which v.19 logs
    -- proved was happening to SET_PREFS after mid-stream disconnects.
    local pairs_list = split_text(payload, ";")
    for _, entry in ipairs(pairs_list) do
      local eq = string.find(entry, "=", 1, true)
      if eq ~= nil then
        local key = string.sub(entry, 1, eq - 1)
        local value = string.sub(entry, eq + 1)
        if key == "brightness" then
          local new_brightness = tonumber(value) or state.brightness
          if new_brightness ~= state.brightness then
            state.brightness = new_brightness
            state.needs_render = true
          end
        elseif key == "partials" then
          state.partials = value == "1"
        end
      end
    end
    send_event({ "EVT", "PREFS_SAVED" })
    return
  end

  if flag == FLAG_SHOW_CAPTION then
    local parts = split_text(payload, "\t")
    local caption_kind = parts[1] or "final"
    local text = parts[2] or ""
    -- flush_caption_text mutates caption state; mark dirty.
    flush_caption_text(text, caption_kind == "partial")
    state.needs_render = true
    return
  end

  if flag == FLAG_SHOW_SUGGESTION then
    local parts = split_text(payload, "\t")
    local new_phonetic = trim(parts[1] or "")
    local new_english = trim(parts[2] or "")
    if new_phonetic ~= state.suggestion_phonetic or new_english ~= state.suggestion_english then
      state.suggestion_phonetic = new_phonetic
      state.suggestion_english = new_english
      state.needs_render = true
    end
    return
  end

  if flag == FLAG_CLEAR_CAPTION then
    local had_content = state.caption_buffer ~= ""
        or #state.caption_lines > 0
        or state.live_partial ~= ""
        or state.suggestion_phonetic ~= ""
        or state.suggestion_english ~= ""
    reset_caption_buffer()
    state.suggestion_phonetic = ""
    state.suggestion_english = ""
    state.scroll_offset = 0
    if had_content then
      state.needs_render = true
    end
    return
  end

  if flag == FLAG_RESET then
    pcall(frame.microphone.stop)
    reset_caption_buffer()
    state.listening = false
    state.suggestion_phonetic = ""
    state.suggestion_english = ""
    state.scroll_offset = 0
    frame.sleep(0.05)
    start_mic()
    state.needs_render = true
    send_event({ "EVT", "RESET_OK" })
    return
  end

  if flag == FLAG_ADMIN_PROBE then
    -- Diagnostic: emit a full SYS_PROBE / HEAP_PROBE / HEAP snapshot of
    -- the firmware C heap and Lua heap state on demand. The payload is
    -- a free-form label (e.g. "after_30s_listen") that gets attached to
    -- the emitted events so multiple probes from one test are
    -- distinguishable in the log.
    local label = (payload ~= nil and payload ~= "") and payload or "admin"
    send_heap("admin_" .. label)
    probe_largest_alloc("admin_" .. label)
    probe_system_heap("admin_" .. label)
    send_event({ "EVT", "ADMIN_PROBE_OK", label })
    return
  end
end

local function on_tap()
  pcall(frame.bluetooth.send, string.char(0x10))
end

local function send_data(payload)
  -- Audio packets: 20 attempts × 1 ms = up to 20 ms blocking, then drop.
  -- Bounded so a saturated BLE TX queue can't stall the main loop and
  -- starve send_event of its chance to deliver high-priority events.
  ble_send(payload, 20)
end

start_mic = function()
  -- Belt-and-suspenders mic teardown. The reconnect handler in the
  -- main loop also runs this sequence; doing it again here covers the
  -- case where listening starts on a connection that never went
  -- through a disconnect (boot path) or where the reconnect handler
  -- somehow didn't fire. 100 ms sleep is longer than the 20 ms we had
  -- in v.10–.16; v.17 evidence suggests the firmware needs more time
  -- between stop and start to fully reset post-reconnect.
  pcall(frame.microphone.stop)
  frame.sleep(0.1)
  send_heap("pre_collect")
  collectgarbage("collect")
  send_heap("pre_mic_start")
  local ok, err = pcall(frame.microphone.start, { sample_rate = 16000, bit_depth = 8 })
  send_heap("post_mic_start")
  local message = tostring(err or "")
  send_event({ "EVT", "MIC_INIT", ok and "1" or "0", message })
  if ok then
    -- Settling delay before first mic.read so any deferred buffer
    -- allocation triggered by mic.start has time to complete.
    frame.sleep(0.1)
    send_heap("post_mic_settle")
    probe_largest_alloc("post_mic_settle")
    pcall(frame.microphone.read, 32)
    send_heap("post_warmup_read")
    probe_largest_alloc("post_warmup_read")
    -- Baseline SYS_PROBE at known-good state so we can compare its
    -- pattern to the failure-time SYS_PROBE. v.24.
    probe_system_heap("post_warmup_read")
    return true
  end
  if string.find(message, "already started", 1, true) ~= nil then
    return true
  end
  send_event({ "EVT", "MIC_ERROR", message })
  return false
end

local function run_app()
  frame.bluetooth.receive_callback(on_packet)
  frame.imu.tap_callback(on_tap)
  pcall(frame.display.set_brightness, state.brightness)
  send_event({ "EVT", "BOOT", frame.FIRMWARE_VERSION, tostring(frame.bluetooth.max_length()), APP_VERSION })
  send_heap("boot")

  -- v.26: audio_data_size is recomputed per iteration in the audio loop
  -- with a clamp. Static-at-boot computation is dangerous because if
  -- frame.bluetooth.max_length() returns -1 at boot (observed when the
  -- Lua VM starts before BLE has finished binding to the connection),
  -- audio_data_size becomes -2, and every mic.read(-2) hits malloc
  -- with size_t(-2) = 0xFFFFFFFE → fails with "not enough memory"
  -- forever. v.25 log SYS_PROBE confirmed: malloc(1024) succeeded at
  -- the same instant mic.read(audio_data_size) failed.
  local AUDIO_DATA_SIZE_MIN = 64
  local AUDIO_DATA_SIZE_MAX = 1024
  local AUDIO_DATA_SIZE_FALLBACK = 240
  local function compute_audio_data_size()
    local mtu_ok, mtu = pcall(frame.bluetooth.max_length)
    if not mtu_ok or type(mtu) ~= "number" then
      return AUDIO_DATA_SIZE_FALLBACK
    end
    local sz = math.floor((mtu - 1) / 2) * 2
    if sz < AUDIO_DATA_SIZE_MIN or sz > AUDIO_DATA_SIZE_MAX then
      return AUDIO_DATA_SIZE_FALLBACK
    end
    return sz
  end

  state.last_message_at = now_seconds()
  maybe_emit_battery(true)

  -- v.22: start the mic ONCE at boot and never call mic.stop in normal
  -- operation. v.21 probe data showed mic.start/mic.stop cycling
  -- fragments the firmware C heap (separate from Lua heap), eventually
  -- starving the audio DMA allocator. mic.read runs every iteration of
  -- the main loop; bytes are only forwarded to iOS when state.listening
  -- is true. This matches noa's app architecture.
  start_mic()

  local audio_first_logged = false
  local mic_nil_streak = 0
  local last_full_gc_at = now_seconds()
  local last_heap_emit_at = 0
  -- v.23: recovery state for the case where boot-time start_mic returns
  -- OK but the firmware audio path never actually came up (observed when
  -- Frame is powered on after a cold rest). On AUDIO_ERROR (20 failed
  -- reads in a row) we cycle mic.stop+mic.start once, then back off for
  -- a few seconds so we don't hammer a stuck mic at 1000 Hz. Capped so
  -- we don't burn the firmware C heap with infinite recovery cycles.
  local mic_recovery_until = 0
  local mic_recovery_attempts = 0
  local MIC_RECOVERY_BACKOFF = 3      -- seconds between recovery attempts
  local MIC_RECOVERY_MAX_ATTEMPTS = 8

  while true do
    -- Drain all fully-assembled commands in arrival order. Per-flag slots
    -- still isolate a stranded message of one flag from blocking another;
    -- the queue tail prevents a burst of same-flag completions from
    -- overwriting each other before dispatch.
    while ready_queue[1] ~= nil do
      local item = ready_queue[1]
      table.remove(ready_queue, 1)
      pcall(handle_command, item.flag, item.payload)
    end

    local now = now_seconds()

    -- Wake render_ui if (a) state changed (needs_render) or (b) auto-
    -- scroll catch-up timer is due. Critical: render_ui is NOT entered
    -- between scroll steps. That used to spam build_render_lines /
    -- wrap_lines ~200×/sec, exhausting the Lua heap and crashing the
    -- audio path with "not enough memory."
    if state.scroll_resume_at > 0 and now > 0 and now >= state.scroll_resume_at then
      state.needs_render = true
    end
    -- Wrapped in pcall so a malformed UTF-8 caption or display-driver
    -- hiccup logs RENDER_ERROR and clears needs_render rather than
    -- killing the main loop.
    if state.needs_render then
      local render_ok, render_err = pcall(render_ui)
      if not render_ok then
        state.needs_render = false
        state.scroll_resume_at = 0
        send_event({ "EVT", "RENDER_ERROR", crash_text(render_err) })
      end
    end

    -- Watchdog: drop any per-flag accumulator slot that's been incomplete
    -- for too long, so a single dropped chunk can't lock out a flag forever.
    -- Per-flag isolation makes this rare; this just bounds the worst case.
    if now > 0 then
      for flag, item in pairs(accum_by_flag) do
        if item.started_at > 0 and (now - item.started_at) > ACCUM_TIMEOUT then
          accum_by_flag[flag] = nil
          send_event({ "EVT", "ACCUM_TIMEOUT", tostring(flag) })
        end
      end
    end

    maybe_emit_battery(false)

    local ok_conn, conn = pcall(frame.bluetooth.is_connected)
    local connected = ok_conn and conn

    -- Disconnect indicator only. v.18 logs proved
    -- frame.bluetooth.is_connected does NOT reliably observe
    -- BLE-disconnect transitions on this firmware, so the post-
    -- reconnect reset that USED to live here was unreachable.
    -- Reset is now triggered by FLAG_SET_PREFS in handle_command,
    -- which iOS sends deterministically on every bootstrap.
    if not connected and not state.disconnected then
      state.disconnected = true
      state.needs_render = true
    elseif connected and state.disconnected then
      state.disconnected = false
      state.last_message_at = now
      state.needs_render = true
    end

    -- True idle deep-sleep. Fires only after IDLE_DEEP_SLEEP seconds of
    -- complete silence. Tap wakes Frame. mic.stop here is the one place
    -- in normal operation we still toggle the mic — power savings for
    -- a 5-minute idle outweigh the firmware-heap risk, and we restart
    -- the mic via start_mic() after wake.
    if state.last_message_at > 0 and now > 0
       and not state.listening
       and (now - state.last_message_at) > IDLE_DEEP_SLEEP then
      pcall(frame.microphone.stop)
      state.listening = false
      state.suggestion_phonetic = ""
      state.suggestion_english = ""
      reset_caption_buffer()
      blank_display()
      frame.sleep(0.05)
      pcall(frame.sleep)
      state.last_message_at = now_seconds()
      start_mic()
      state.needs_render = true
    end

    -- v.22: mic.read runs every iteration regardless of listening state;
    -- bytes are forwarded to iOS only when state.listening is true. The
    -- mic stays running across listen toggles to avoid the
    -- start/stop-cycling firmware-C-heap fragmentation that caused the
    -- v.21 OOM.
    -- v.23: if persistent failures (20-in-a-row = AUDIO_ERROR) happen
    -- (e.g. cold-start race where mic.start returned OK but the audio
    -- subsystem never came up), cycle mic.stop+start once with backoff.
    -- During backoff we skip mic.read entirely so we don't hammer a
    -- stuck mic at 1000 Hz and so the BLE TX queue can drain.
    local in_recovery_cooldown = (mic_recovery_until > 0 and now > 0 and now < mic_recovery_until)
    if now > 0 and state.listening and (now - last_heap_emit_at) >= 5 then
      last_heap_emit_at = now
      send_heap("listening")
    end
    if state.listening and not audio_first_logged and not in_recovery_cooldown then
      send_heap("pre_first_mic_read")
      probe_largest_alloc("pre_first_mic_read")
    end
    local read_error_streak = 0
    local last_read_err = nil
    -- v.26: recompute the read size each tick so a transiently bogus
    -- max_length() (e.g. -1 right after a BLE rebind) can't poison the
    -- value for the rest of the session. Clamped to a known-safe range.
    local audio_data_size = compute_audio_data_size()
    if not in_recovery_cooldown then
      for _ = 1, 20 do
        local read_ok, audio = pcall(frame.microphone.read, audio_data_size)
        if not read_ok then
          read_error_streak = read_error_streak + 1
          last_read_err = audio
          if read_error_streak == 1 then
            send_heap("at_read_err")
            probe_largest_alloc("at_read_err")
            probe_system_heap("at_read_err")
            -- Emit the read size + raw max_length so the next failure log
            -- proves whether audio_data_size is the culprit. v.26.
            local mtu_ok, mtu = pcall(frame.bluetooth.max_length)
            send_event({ "EVT", "MIC_READ_PARAMS",
                         tostring(audio_data_size),
                         mtu_ok and tostring(mtu) or "ERR" })
            send_event({ "EVT", "MIC_READ_ERR", tostring(read_error_streak), crash_text(audio) })
          end
          frame.sleep(0.01)
        elseif audio == nil then
          mic_nil_streak = mic_nil_streak + 1
          if mic_nil_streak == 1 or (mic_nil_streak % 50) == 0 then
            send_event({ "EVT", "MIC_READ_NIL", tostring(mic_nil_streak) })
            send_heap("at_mic_nil")
          end
          frame.sleep(0.1)
          break
        elseif audio ~= "" then
          if read_error_streak > 0 then
            send_event({ "EVT", "MIC_READ_RECOVERED", tostring(read_error_streak) })
            read_error_streak = 0
          end
          mic_nil_streak = 0
          mic_recovery_attempts = 0
          if state.listening then
            if not audio_first_logged then
              send_event({ "EVT", "MIC_READ_BYTES", tostring(string.len(audio)) })
              audio_first_logged = true
              send_heap("post_first_packet")
            end
            pcall(send_data, string.char(0x05) .. audio)
          end
          audio = nil
        else
          break
        end
      end
    end
    if read_error_streak >= 20 then
      send_heap("at_audio_error")
      probe_largest_alloc("at_audio_error")
      probe_system_heap("at_audio_error")
      send_event({ "EVT", "AUDIO_ERROR", crash_text(last_read_err) })
      -- Gate recovery on whether the firmware C heap can satisfy a
      -- 4-byte malloc. Per microphone.c, mic.read() = malloc(N); if
      -- even N=4 errors, the heap is exhausted and mic.stop+start
      -- can't help (per firmware analysis, nrfx_pdm_uninit is never
      -- called, so PDM state isn't actually reset). Surface a
      -- permanent-failure event so iOS can prompt for a power cycle.
      local probe_ok, _ = pcall(frame.microphone.read, 4)
      if probe_ok and mic_recovery_attempts < MIC_RECOVERY_MAX_ATTEMPTS then
        mic_recovery_attempts = mic_recovery_attempts + 1
        send_event({ "EVT", "MIC_RECOVERY_TRY", tostring(mic_recovery_attempts) })
        pcall(frame.microphone.stop)
        frame.sleep(0.2)
        local rs_ok, rs_err = pcall(frame.microphone.start, { sample_rate = 16000, bit_depth = 8 })
        send_event({ "EVT", "MIC_RECOVERY_RESULT", rs_ok and "1" or "0", tostring(rs_err or "") })
        if now > 0 then
          mic_recovery_until = now + MIC_RECOVERY_BACKOFF
        end
      else
        send_event({ "EVT", "MIC_PERMANENT_FAILURE", probe_ok and "max_attempts" or "heap_exhausted",
                     tostring(mic_recovery_attempts) })
        if now > 0 then
          mic_recovery_until = now + 60
        end
      end
    end
    if not state.listening then
      audio_first_logged = false
    end

    frame.sleep(0.001)
    -- GC strategy is mode-dependent. Streaming audio creates ~16 KB/s of
    -- new strings (`string.char(0x05) .. audio` per packet) on top of
    -- accumulator and render allocations — incremental steps can't keep
    -- up and the heap eventually OOMs ("not enough memory"). When
    -- listening, run a full collect each tick (matches noa's reference
    -- under the same workload). When idle, the cheaper step + periodic
    -- full keeps the per-iteration cost low.
    if state.listening then
      collectgarbage("collect")
      last_full_gc_at = now
    else
      collectgarbage("step", 1)
      if now > 0 and (now - last_full_gc_at) >= FULL_GC_INTERVAL then
        collectgarbage("collect")
        last_full_gc_at = now
      end
    end
  end
end

local ok, err = xpcall(run_app, debug.traceback)
if not ok then
  -- Best-effort crash event over BLE (no filesystem persistence). If
  -- the send fails (BLE saturated), we still enter the dead-state
  -- sleep loop below — reinstall is the recovery path.
  local payload = "EVT\tCRASH\t" .. crash_text(err)
  for _ = 1, 1000 do
    local send_ok, send_result = pcall(frame.bluetooth.send, payload)
    if send_ok and send_result ~= false then break end
    pcall(frame.sleep, 0.001)
  end
  blank_display()
  while true do
    frame.sleep(1)
  end
end
"""#
}
