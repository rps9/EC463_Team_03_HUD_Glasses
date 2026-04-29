import Foundation

enum FrameEmbeddedApp {
    static let mainLua = #"""
local APP_DIR = "/hudini"
local APP_VERSION = "2026.04.28.10"
local CRASH_PATH = APP_DIR .. "/crash.txt"

local CAPTION_LINE_LIMIT = 30
local CAPTION_LINE_HISTORY = 50
local BATTERY_CHECK_INTERVAL = 60   -- seconds between cheap level reads
local BATTERY_FORCE_INTERVAL = 600  -- seconds between forced re-emits
local IDLE_PRE_SLEEP = 30           -- seconds of message silence before pre-sleep warning
local IDLE_DEEP_SLEEP = 60          -- seconds of message silence before frame.sleep()

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
  sleep_started = false,
}

frame.display.text("HUDini", 220, 116, { color = "WHITE", spacing = 4 })
frame.display.text("Loading...", 210, 154, { color = "LIGHTGREEN", spacing = 4 })
frame.display.show()

-- Single-channel chunking accumulator. The Frame firmware strips the iOS
-- `0x01` "data prefix" byte before delivering to `frame.bluetooth.receive_callback`,
-- so what we see here is:
--   first chunk    = [size_hi][size_lo][payload bytes...]
--   continuation   = [payload bytes...]
-- Once `recv_bytes >= size` we have the full assembled command payload.
-- A pending payload sits in `accum.ready` for the main loop to pick up.
local accum = {
  chunks = {},
  num_chunks = 0,
  size = 0,
  recv_bytes = 0,
  ready = nil,
}

local function on_packet(packet)
  pcall(function()
    if accum.num_chunks == 0 then
      accum.size = (string.byte(packet, 1) << 8) | string.byte(packet, 2)
      accum.chunks[1] = string.sub(packet, 3)
      accum.num_chunks = 1
      accum.recv_bytes = string.len(packet) - 2
    else
      accum.num_chunks = accum.num_chunks + 1
      accum.chunks[accum.num_chunks] = packet
      accum.recv_bytes = accum.recv_bytes + string.len(packet)
    end

    if accum.recv_bytes >= accum.size and accum.size > 0 then
      accum.ready = table.concat(accum.chunks)
      for k in pairs(accum.chunks) do accum.chunks[k] = nil end
      accum.num_chunks = 0
      accum.size = 0
      accum.recv_bytes = 0
    end
  end)
end

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

local function send_event(parts)
  local payload = table.concat(parts, "\t")
  pcall(frame.bluetooth.send, payload)
end

local function now_seconds()
  local ok, value = pcall(frame.time.utc)
  if ok and type(value) == "number" then
    return value
  end
  return 0
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

-- Layout (Frame display 640x400), top-down, dynamically packed:
--   Y 12          mic indicator (left) + status indicator (right)
--   Y 60+         transcription rows, SKYBLUE, up to 3 lines
--   next row+     suggestion English meaning, WHITE, up to 2 lines
--   next row+     suggestion phonetic to speak, YELLOW, up to 2 lines
-- Each row is 45 px tall; regions abut with no inter-region gap. The 60 px
-- top offset keeps the first transcription row clear of the mic indicator.
local function render_ui()
  state.needs_render = false

  pcall(frame.display.set_brightness, state.brightness)

  frame.display.text("Mic:", 24, 12, { color = "WHITE", spacing = 2 })
  frame.display.text(state.listening and "ON" or "OFF", 98, 12,
    { color = state.listening and "GREEN" or "RED", spacing = 2 })

  if state.disconnected then
    frame.display.text("disconnected", 380, 12, { color = "RED", spacing = 2 })
  elseif state.sleep_started then
    frame.display.text("idle", 540, 12, { color = "GRAY", spacing = 2 })
  end

  -- Transcription region (top, SKYBLUE) - what the partner said, in English.
  local visible = {}
  local n = #state.caption_lines
  if n >= 3 then table.insert(visible, state.caption_lines[n - 2]) end
  if n >= 2 then table.insert(visible, state.caption_lines[n - 1]) end
  if n >= 1 then table.insert(visible, state.caption_lines[n]) end
  if state.live_partial ~= "" then
    table.insert(visible, string.sub(state.live_partial, 1, CAPTION_LINE_LIMIT))
  elseif state.caption_buffer ~= "" then
    table.insert(visible, state.caption_buffer)
  end
  while #visible > 3 do
    table.remove(visible, 1)
  end

  local y = 60
  for _, line in ipairs(visible) do
    frame.display.text(line, 24, y, { color = "SKYBLUE", spacing = 4 })
    y = y + 45
  end

  -- Suggestion: English meaning (WHITE) above the phonetic to speak (YELLOW),
  -- both packed immediately below whatever transcription rendered. No "SAY:"
  -- label; the YELLOW row is the words to actually pronounce.
  if state.suggestion_english ~= "" then
    y = draw_multiline(state.suggestion_english, 24, y, "WHITE", CAPTION_LINE_LIMIT, 2)
  end
  if state.suggestion_phonetic ~= "" then
    y = draw_multiline(state.suggestion_phonetic, 24, y, "YELLOW", CAPTION_LINE_LIMIT, 2)
  end

  frame.display.show()
end

local function handle_command(payload)
  local parts = split_text(payload, "\t")
  local command = parts[1]
  if command == nil then return end

  state.last_message_at = now_seconds()
  state.sleep_started = false
  state.disconnected = false
  state.needs_render = true

  if command == "PING" then
    send_event({ "EVT", "READY", frame.FIRMWARE_VERSION, tostring(frame.bluetooth.max_length()), APP_VERSION })
    return
  end

  if command == "SYNC_STATE" then
    local was_listening = state.listening
    state.listening = parts[2] == "1"
    state.status = parts[3] or (state.listening and "listening" or "idle")
    if state.listening and not was_listening then
      state.suggestion_phonetic = ""
      state.suggestion_english = ""
      reset_caption_buffer()
      start_mic()
    elseif was_listening and not state.listening then
      pcall(frame.microphone.stop)
    end
    send_event({ "EVT", "STATUS", state.status })
    return
  end

  if command == "SET_PREFS" then
    local pairs_list = split_text(parts[2] or "", ";")
    for _, entry in ipairs(pairs_list) do
      local eq = string.find(entry, "=", 1, true)
      if eq ~= nil then
        local key = string.sub(entry, 1, eq - 1)
        local value = string.sub(entry, eq + 1)
        if key == "brightness" then
          state.brightness = tonumber(value) or state.brightness
        elseif key == "partials" then
          state.partials = value == "1"
        end
      end
    end
    send_event({ "EVT", "PREFS_SAVED" })
    return
  end

  if command == "SHOW_CAPTION" then
    local caption_kind = parts[2] or "final"
    local text = parts[3] or ""
    flush_caption_text(text, caption_kind == "partial")
    return
  end

  if command == "SHOW_SUGGESTION" then
    state.suggestion_phonetic = trim(parts[2] or "")
    state.suggestion_english = trim(parts[3] or "")
    return
  end

  if command == "CLEAR_CAPTION" then
    reset_caption_buffer()
    state.suggestion_phonetic = ""
    state.suggestion_english = ""
    return
  end

  if command == "RESET" then
    pcall(frame.microphone.stop)
    reset_caption_buffer()
    state.listening = false
    state.suggestion_phonetic = ""
    state.suggestion_english = ""
    frame.sleep(0.05)
    start_mic()
    send_event({ "EVT", "RESET_OK" })
    return
  end
end

local function on_tap()
  pcall(frame.bluetooth.send, string.char(0x10))
end

local function send_data(payload)
  for _ = 1, 100 do
    if pcall(frame.bluetooth.send, payload) then
      return
    end
    frame.sleep(0.001)
  end
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

  local last_render_at = 0
  local audio_first_logged = false
  local mic_nil_streak = 0

  while true do
    -- Dispatch a fully-assembled command if the accumulator has one ready.
    if accum.ready ~= nil then
      local payload = accum.ready
      accum.ready = nil
      pcall(handle_command, payload)
    end

    -- Match noa: refresh the OLED on a steady cadence so it never appears
    -- to dim/blank. Also honors immediate state-change requests.
    local now = now_seconds()
    if state.needs_render or (now - last_render_at) > 0.5 then
      render_ui()
      last_render_at = now
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
      state.sleep_started = false
      state.needs_render = true
    end

    -- Idle sleep is keyed on `last_message_at`. If `now_seconds()` is 0
    -- (clock not yet synced) we skip these checks to avoid false trips.
    if state.last_message_at > 0 and now > 0 then
      if (now - state.last_message_at) > IDLE_PRE_SLEEP
         and not state.sleep_started
         and not state.listening then
        state.sleep_started = true
        state.needs_render = true
      end

      if (now - state.last_message_at) > IDLE_DEEP_SLEEP and state.sleep_started then
        pcall(frame.microphone.stop)
        state.listening = false
        state.suggestion_phonetic = ""
        state.suggestion_english = ""
        reset_caption_buffer()
        blank_display()
        frame.sleep(0.05)
        pcall(frame.sleep)
        state.last_message_at = now_seconds()
        state.sleep_started = false
        state.needs_render = true
      end
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
    collectgarbage("collect")
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
