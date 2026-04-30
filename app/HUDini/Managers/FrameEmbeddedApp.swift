import Foundation

enum FrameEmbeddedApp {
    static let mainLua = #"""
local APP_DIR = "/hudini"
local APP_VERSION = "2026.04.30.2"
local CRASH_PATH = APP_DIR .. "/crash.txt"

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
}

frame.display.text("HUDini", 220, 116, { color = "WHITE", spacing = 4 })
frame.display.text("Loading...", 210, 154, { color = "LIGHTGREEN", spacing = 4 })
frame.display.show()

local function ensure_dir()
  pcall(frame.file.mkdir, APP_DIR)
end

local function crash_text(err)
  local text = tostring(err or "unknown error")
  if string.len(text) > 240 then
    text = string.sub(text, 1, 240)
  end
  return text
end

local function save_crash(err)
  ensure_dir()
  local f = frame.file.open(CRASH_PATH, "write")
  if f ~= nil then
    f:write(crash_text(err) .. "\n")
    f:close()
  end
end

local function emit_crash(err)
  pcall(frame.bluetooth.send, "EVT\tCRASH\t" .. crash_text(err))
end

local function load_saved_crash()
  local ok, f = pcall(frame.file.open, CRASH_PATH, "read")
  if not ok or f == nil then
    return nil
  end
  local line = f:read()
  f:close()
  return line
end

local function clear_saved_crash()
  pcall(frame.file.remove, CRASH_PATH)
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

  local lines = build_render_lines()
  local total = #lines
  local target_offset = math.max(0, total - DISPLAY_MAX_LINES)
  local now = now_seconds()

  -- Content shrank? Snap up immediately so we're not stranded mid-scroll.
  if state.scroll_offset > target_offset then
    state.scroll_offset = target_offset
  end

  -- If content overflows and we haven't reached the bottom yet, gate the
  -- actual paint on SCROLL_LINE_INTERVAL. Returning early without
  -- clearing `needs_render` keeps the main loop polling cheaply (~ µs)
  -- until it's time for the next scroll step. Without this gate we'd
  -- flush the OLED 200×/sec while waiting.
  if state.scroll_offset < target_offset then
    if state.last_scroll_at == 0 and now > 0 then
      state.last_scroll_at = now
    end
    if now > 0 and (now - state.last_scroll_at) >= SCROLL_LINE_INTERVAL then
      state.scroll_offset = state.scroll_offset + 1
      state.last_scroll_at = now
    else
      -- Not yet time to advance. Keep needs_render set; come back later.
      return
    end
  end

  -- About to paint. Clear the dirty flag, but re-arm if more scroll steps
  -- are still pending so the next iteration re-enters render_ui.
  state.needs_render = (state.scroll_offset < target_offset)

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
    send_event({ "EVT", "READY", frame.FIRMWARE_VERSION, tostring(frame.bluetooth.max_length()), APP_VERSION })
    return
  end

  if flag == FLAG_SYNC_STATE then
    local parts = split_text(payload, "\t")
    local was_listening = state.listening
    state.listening = parts[1] == "1"
    state.status = parts[2] or (state.listening and "listening" or "idle")
    -- Emit STATUS *before* mic transitions. Mic start/stop and the
    -- subsequent audio drain compete for the BLE TX queue; getting STATUS
    -- onto the wire first guarantees iOS sees the state change promptly.
    send_event({ "EVT", "STATUS", state.status })
    if state.listening and not was_listening then
      state.suggestion_phonetic = ""
      state.suggestion_english = ""
      reset_caption_buffer()
      state.scroll_offset = 0
      start_mic()
      state.needs_render = true
    elseif was_listening and not state.listening then
      pcall(frame.microphone.stop)
      state.needs_render = true
    end
    return
  end

  if flag == FLAG_SET_PREFS then
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
  -- 16 kHz / 8-bit is the validated config for this iOS Speech pipeline.
  -- Don't switch to noa's empty-table defaults (8 kHz / 8-bit) - recognition fails.
  local ok, err = pcall(frame.microphone.start, { sample_rate = 16000, bit_depth = 8 })
  local message = tostring(err or "")
  send_event({ "EVT", "MIC_INIT", ok and "1" or "0", message })
  if ok then
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

  local saved_crash = load_saved_crash()
  if saved_crash ~= nil and saved_crash ~= "" then
    send_event({ "EVT", "CRASH", crash_text(saved_crash) })
    clear_saved_crash()
  end

  local audio_data_size = math.floor((frame.bluetooth.max_length() - 1) / 2) * 2

  state.last_message_at = now_seconds()
  maybe_emit_battery(true)

  local audio_first_logged = false
  local mic_nil_streak = 0
  local last_full_gc_at = now_seconds()

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

    -- Repaint only when state changed. The OLED holds its framebuffer; no
    -- periodic refresh needed.
    if state.needs_render then
      render_ui()
    end

    local now = now_seconds()

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

    -- Disconnect indicator only. Does NOT trigger sleep.
    if not connected and not state.disconnected then
      state.disconnected = true
      state.needs_render = true
    elseif connected and state.disconnected then
      state.disconnected = false
      state.last_message_at = now
      state.needs_render = true
    end

    -- True idle deep-sleep. Fires only after IDLE_DEEP_SLEEP seconds of
    -- complete silence (no inbound commands, mic off). Tap wakes Frame.
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
      state.needs_render = true
    end

    if state.listening then
      for _ = 1, 20 do
        local audio = frame.microphone.read(audio_data_size)
        if audio == nil then
          mic_nil_streak = mic_nil_streak + 1
          if mic_nil_streak == 1 or (mic_nil_streak % 50) == 0 then
            send_event({ "EVT", "MIC_READ_NIL", tostring(mic_nil_streak) })
          end
          frame.sleep(0.1)
          start_mic()
          break
        elseif audio ~= "" then
          mic_nil_streak = 0
          if not audio_first_logged then
            send_event({ "EVT", "MIC_READ_BYTES", tostring(string.len(audio)) })
            audio_first_logged = true
          end
          pcall(send_data, string.char(0x05) .. audio)
        else
          break
        end
      end
    else
      audio_first_logged = false
      mic_nil_streak = 0
    end

    frame.sleep(0.001)
    -- Incremental GC each tick keeps the heap walking in small slices
    -- (~0.1–0.5 ms) instead of paying for a full collect every iteration.
    -- A full `collect` runs every FULL_GC_INTERVAL seconds to claw back
    -- anything the incremental sweep missed.
    collectgarbage("step", 1)
    if now > 0 and (now - last_full_gc_at) >= FULL_GC_INTERVAL then
      collectgarbage("collect")
      last_full_gc_at = now
    end
  end
end

local ok, err = xpcall(run_app, debug.traceback)
if not ok then
  save_crash(err)
  emit_crash(err)
  blank_display()
  while true do
    frame.sleep(1)
  end
end
"""#
}
