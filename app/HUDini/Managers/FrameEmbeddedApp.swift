import Foundation

enum FrameEmbeddedApp {
    static let mainLua = #"""
local APP_DIR = "/hudini"
local APP_VERSION = "2026.04.08.7"
local CRASH_PATH = APP_DIR .. "/crash.txt"

local state = {
  connected = false,
  status = "idle",
  listening = false,
  partial_caption = "",
  final_caption = "",
  brightness = 0,
  partials = true,
  needs_render = true,
  audio_sequence = 0,
  tap_sequence = 0,
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

  local text = state.final_caption
  if text == "" and state.partials then
    text = state.partial_caption
  end
  draw_multiline(text, 24, 98, "SKYBLUE", 30, 6)

  frame.display.show()
  state.needs_render = false
end

local function handle_command(payload)
  local parts = split_text(payload, "\t")
  local command = parts[1]

  if command ~= nil then
    state.connected = true
    state.needs_render = true
  end

  if command == "PING" then
    send_event({ "EVT", "READY", frame.FIRMWARE_VERSION, tostring(frame.bluetooth.max_length()), APP_VERSION })
    return
  end

  if command == "SYNC_STATE" then
    state.listening = parts[2] == "1"
    state.status = parts[3] or (state.listening and "listening" or "idle")
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
    if caption_kind == "partial" then
      state.partial_caption = trim(text)
      if not state.partials then
        state.partial_caption = ""
      end
    else
      state.final_caption = trim(text)
      state.partial_caption = ""
    end
    state.needs_render = true
    return
  end

  if command == "CLEAR_CAPTION" then
    state.partial_caption = ""
    state.final_caption = ""
    state.needs_render = true
    return
  end

  if command == "RESET" then
    pcall(frame.microphone.stop)
    state.partial_caption = ""
    state.final_caption = ""
    state.listening = false
    state.audio_sequence = 0
    send_buffer = ""
    state.needs_render = true
    frame.sleep(0.05)
    start_mic()
    send_event({ "EVT", "RESET_OK" })
    return
  end
end

local function on_tap()
  state.tap_sequence = state.tap_sequence + 1
  send_event({
    "EVT",
    "MIC_REQUEST",
    state.listening and "1" or "0",
    state.listening and "0" or "1",
    tostring(state.tap_sequence),
  })
end

local function send_audio_chunk(data)
  local sequence = state.audio_sequence
  local packet = string.char(0x20, sequence % 256, math.floor(sequence / 256) % 256) .. data
  for _ = 1, 3 do
    if pcall(frame.bluetooth.send, packet) then
      break
    end
    frame.sleep(0.001)
  end
  state.audio_sequence = (sequence + 1) % 65536
end

local function start_mic()
  local ok, err = pcall(frame.microphone.start, { sample_rate = 8000, bit_depth = 16 })
  if ok then
    state.audio_sequence = 0
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

  local max_audio_bytes = frame.bluetooth.max_length() - 3
  if max_audio_bytes % 2 == 1 then
    max_audio_bytes = max_audio_bytes - 1
  end
  if max_audio_bytes < 64 then
    max_audio_bytes = 64
  end

  start_mic()
  send_buffer = ""

  while true do
    if state.needs_render then
      render_ui()
    end

    local audio = frame.microphone.read(max_audio_bytes)
    if audio == nil then
      if send_buffer ~= "" then
        send_audio_chunk(send_buffer)
        send_buffer = ""
      end
      frame.sleep(0.1)
      start_mic()
    elseif audio ~= "" then
      send_buffer = send_buffer .. audio
      if string.len(send_buffer) >= max_audio_bytes then
        send_audio_chunk(string.sub(send_buffer, 1, max_audio_bytes))
        send_buffer = string.sub(send_buffer, max_audio_bytes + 1)
      end
    else
      if send_buffer ~= "" then
        send_audio_chunk(send_buffer)
        send_buffer = ""
      end
      frame.sleep(0.004)
    end
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
"""#
}
