local APP_DIR = "/hudini"
local APP_VERSION = "2026.04.28.3"
local CRASH_PATH = APP_DIR .. "/crash.txt"

local CAPTION_LINE_LIMIT = 30
local CAPTION_LINE_HISTORY = 50
local BATTERY_CHECK_INTERVAL = 60   -- seconds between cheap level reads
local BATTERY_FORCE_INTERVAL = 600  -- seconds between forced re-emits
local IDLE_TIMEOUT = 60             -- seconds without any inbound command -> deep sleep

-- Forward declaration so handle_command can reference start_mic on SYNC_STATE / RESET
local start_mic

local state = {
  connected = false,
  status = "idle",
  listening = false,
  brightness = 2,
  partials = true,
  needs_render = true,
  suggestion = "",
  -- Rolling caption buffer (Noa-style append-and-scroll)
  caption_lines = {},
  caption_buffer = "",
  last_caption_text = "",
  live_partial = "",
  last_battery_check_at = 0,
  last_battery_emit_at = 0,
  last_battery_level = -1,
  last_message_at = 0,
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
  if not force and not state.connected then return end
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

local function render_ui()
  if not state.connected then
    frame.display.power_save(true)
    state.needs_render = false
    return
  end

  frame.display.power_save(false)
  frame.display.set_brightness(state.brightness)

  frame.display.text("Mic:", 24, 52, { color = "WHITE", spacing = 4 })
  frame.display.text(state.listening and "ON" or "OFF", 98, 52, { color = state.listening and "GREEN" or "RED", spacing = 4 })

  local visible = {}
  local n = #state.caption_lines
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

  local caption_y = 98
  for _, line in ipairs(visible) do
    frame.display.text(line, 24, caption_y, { color = "SKYBLUE", spacing = 4 })
    caption_y = caption_y + 45
  end

  if state.suggestion ~= "" then
    draw_multiline(state.suggestion, 24, caption_y, "YELLOW", 30, 3)
  end

  frame.display.show()
  state.needs_render = false
end

local function handle_command(payload)
  local parts = split_text(payload, "\t")
  local command = parts[1]

  if command ~= nil then
    state.connected = true
    state.needs_render = true
    state.last_message_at = now_seconds()
  end

  if command == "PING" then
    send_event({ "EVT", "READY", frame.FIRMWARE_VERSION, tostring(frame.bluetooth.max_length()), APP_VERSION })
    return
  end

  if command == "SYNC_STATE" then
    local was_listening = state.listening
    state.listening = parts[2] == "1"
    state.status = parts[3] or (state.listening and "listening" or "idle")
    if state.listening and not was_listening then
      state.suggestion = ""
      reset_caption_buffer()
      start_mic()
    elseif was_listening and not state.listening then
      pcall(frame.microphone.stop)
    end
    state.needs_render = true
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
    state.needs_render = true
    send_event({ "EVT", "PREFS_SAVED" })
    return
  end

  if command == "SHOW_CAPTION" then
    local caption_kind = parts[2] or "final"
    local text = parts[3] or ""
    flush_caption_text(text, caption_kind == "partial")
    state.needs_render = true
    return
  end

  if command == "SHOW_SUGGESTION" then
    state.suggestion = trim(parts[2] or "")
    state.needs_render = true
    return
  end

  if command == "CLEAR_CAPTION" then
    reset_caption_buffer()
    state.suggestion = ""
    state.needs_render = true
    return
  end

  if command == "RESET" then
    pcall(frame.microphone.stop)
    reset_caption_buffer()
    state.listening = false
    state.suggestion = ""
    state.needs_render = true
    frame.sleep(0.05)
    start_mic()
    send_event({ "EVT", "RESET_OK" })
    return
  end
end

local function on_tap()
  pcall(frame.bluetooth.send, string.char(0x10))
end

local function send_data(data)
  for _ = 1, 100 do
    if pcall(frame.bluetooth.send, data) then
      return
    end
    frame.sleep(0.001)
  end
end

start_mic = function()
  local ok, err = pcall(frame.microphone.start, { sample_rate = 16000, bit_depth = 8 })
  if ok then
    return true
  end
  local message = tostring(err or "")
  if string.find(message, "already started", 1, true) ~= nil then
    return true
  end
  send_event({ "EVT", "MIC_ERROR", message })
  return false
end

local function run_app()
  frame.bluetooth.receive_callback(function(data) handle_command(data) end)
  frame.imu.tap_callback(on_tap)
  frame.display.set_brightness(state.brightness)
  state.connected = false
  send_event({ "EVT", "BOOT", frame.FIRMWARE_VERSION, tostring(frame.bluetooth.max_length()), APP_VERSION })

  local saved_crash = load_saved_crash()
  if saved_crash ~= nil and saved_crash ~= "" then
    send_event({ "EVT", "CRASH", crash_text(saved_crash) })
    clear_saved_crash()
  end

  local audio_data_size = math.floor((frame.bluetooth.max_length() - 1) / 2) * 2

  state.last_message_at = now_seconds()
  maybe_emit_battery(true)

  while true do
    if state.needs_render then
      render_ui()
    end

    maybe_emit_battery(false)

    local now = now_seconds()
    local ok_conn, conn = pcall(frame.bluetooth.is_connected)
    local connected = ok_conn and conn
    if not connected or (now - state.last_message_at) > IDLE_TIMEOUT then
      pcall(frame.microphone.stop)
      state.listening = false
      state.connected = false
      state.suggestion = ""
      reset_caption_buffer()
      pcall(frame.display.power_save, true)
      pcall(frame.display.show)
      pcall(frame.sleep)
      state.last_message_at = now_seconds()
    end

    if state.listening then
      for i = 1, 20 do
        local audio = frame.microphone.read(audio_data_size)
        if audio == nil then
          frame.sleep(0.1)
          start_mic()
          break
        elseif audio ~= "" then
          pcall(send_data, string.char(0x05) .. audio)
        else
          break
        end
      end
    end

    frame.sleep(0.001)
  end
end

local ok, err = xpcall(run_app, debug.traceback)
if not ok then
  save_crash(err)
  emit_crash(err)
  pcall(frame.display.power_save, true)
  while true do
    frame.sleep(1)
  end
end
