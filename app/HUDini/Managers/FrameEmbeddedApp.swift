import Foundation

enum FrameEmbeddedApp {
    static let mainLua = #"""
local APP_DIR = "/hudini"
local PREFS_PATH = APP_DIR .. "/prefs.txt"
local CRASH_PATH = APP_DIR .. "/crash.txt"

local DEFAULT_PREFS = {
  brightness = 0,
  partials = true,
  position = "bottom",
  layout = "focus",
  transcription_color = "GREY",
  translation_color = "SKYBLUE",
}

local VALID_POSITIONS = {
  top = true,
  middle = true,
  bottom = true,
}

local VALID_LAYOUTS = {
  focus = true,
  split = true,
  compact = true,
}

local VALID_COLORS = {
  WHITE = true,
  GREY = true,
  RED = true,
  PINK = true,
  DARKBROWN = true,
  BROWN = true,
  ORANGE = true,
  YELLOW = true,
  DARKGREEN = true,
  GREEN = true,
  LIGHTGREEN = true,
  NIGHTBLUE = true,
  SEABLUE = true,
  SKYBLUE = true,
  CLOUDBLUE = true,
}

local state = {
  connected = false,
  status = "disconnected",
  mode = "translation",
  partial_caption = "",
  final_caption = "",
  transcript_text = "",
  muted = false,
  mic_display_on = false,
  mic_active = false,
  prefs = nil,
  needs_render = true,
  suggestion_index = 1,
  suggestions = {
    { text = "", phonetic = "" },
    { text = "", phonetic = "" },
    { text = "", phonetic = "" },
  },
  audio_sequence = 0,
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

local function show_crash(err)
  local text = crash_text(err)
  frame.display.text("HUDini crash", 24, 56, { color = "RED", spacing = 4 })
  frame.display.text("Check /hudini/crash.txt", 24, 88, { color = "YELLOW", spacing = 4 })
  frame.display.text(text, 24, 140, { color = "WHITE", spacing = 4 })
  frame.display.show()
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

local function bool_string(value)
  if value then
    return "1"
  end
  return "0"
end

local function load_prefs()
  ensure_dir()
  local prefs = {}
  for key, value in pairs(DEFAULT_PREFS) do
    prefs[key] = value
  end

  local ok, f = pcall(frame.file.open, PREFS_PATH, "read")
  if not ok or f == nil then
    return prefs
  end

  while true do
    local line = f:read()
    if line == nil then
      break
    end
    local eq = string.find(line, "=", 1, true)
    if eq ~= nil then
      local key = string.sub(line, 1, eq - 1)
      local value = string.sub(line, eq + 1)
      if key == "brightness" then
        prefs.brightness = tonumber(value) or prefs.brightness
      elseif key == "partials" then
        prefs.partials = value == "1"
      elseif key == "position" then
        if VALID_POSITIONS[value] then
          prefs.position = value
        end
      elseif key == "layout" then
        if VALID_LAYOUTS[value] then
          prefs.layout = value
        end
      elseif key == "transcription_color" then
        if VALID_COLORS[value] then
          prefs.transcription_color = value
        end
      elseif key == "translation_color" then
        if VALID_COLORS[value] then
          prefs.translation_color = value
        end
      end
    end
  end

  f:close()
  return prefs
end

local function save_prefs()
  ensure_dir()
  local ok, f = pcall(frame.file.open, PREFS_PATH, "write")
  if not ok or f == nil then
    return false
  end

  f:write("brightness=" .. tostring(state.prefs.brightness) .. "\n")
  f:write("partials=" .. bool_string(state.prefs.partials) .. "\n")
  f:write("position=" .. state.prefs.position .. "\n")
  f:write("layout=" .. state.prefs.layout .. "\n")
  f:write("transcription_color=" .. state.prefs.transcription_color .. "\n")
  f:write("translation_color=" .. state.prefs.translation_color .. "\n")
  f:close()
  return true
end

local function send_event(parts)
  local payload = table.concat(parts, "\t")
  pcall(frame.bluetooth.send, payload)
end

local function set_status(status)
  state.status = status
  state.needs_render = true
  send_event({ "EVT", "STATUS", status })
end

local function caption_y()
  if state.prefs.position == "top" then
    return 96
  end
  if state.prefs.position == "middle" then
    return 136
  end
  return 176
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
    line_y = line_y + 32
  end
  return line_y
end

local function draw_section(title, text, x, y, title_color, text_color, max_chars, max_lines)
  local normalized = normalize_display_text(text)
  if normalized == "" then
    return y
  end

  frame.display.text(title, x, y, { color = title_color, spacing = 4 })
  return draw_multiline(normalized, x, y + 28, text_color, max_chars, max_lines)
end

local function active_suggestion()
  local suggestion = state.suggestions[state.suggestion_index]
  if suggestion == nil or suggestion.text == "" then
    return nil
  end
  return suggestion
end

local function render_ui()
  local mic_on = state.mic_display_on
  local mic_color = mic_on and "GREEN" or "RED"

  frame.display.set_brightness(state.prefs.brightness)

  if not state.connected then
    frame.display.text("HUDini", 220, 116, { color = "WHITE", spacing = 4 })
    frame.display.text("Awaiting connection", 150, 132, { color = "SKYBLUE", spacing = 4 })
    frame.display.text("Open HUDini on iPhone", 145, 178, { color = "WHITE", spacing = 4 })
    frame.display.text("Scan and Connect", 172, 224, { color = "LIGHTGREEN", spacing = 4 })
  else
    frame.display.text("Mic:", 24, 52, { color = "WHITE", spacing = 4 })
    frame.display.text(mic_on and "ON" or "OFF", 98, 52, { color = mic_color, spacing = 4 })

    local transcript_bottom = draw_multiline(state.transcript_text, 24, 92, state.prefs.transcription_color, 28, 3)
    local translation_y = 92
    if transcript_bottom > 92 then
      translation_y = transcript_bottom + 14
    end

    local translated = state.final_caption
    if translated == "" and state.prefs.partials then
      translated = state.partial_caption
    end
    draw_multiline(translated, 24, translation_y, state.prefs.translation_color, 28, 5)
  end

  frame.display.show()
  state.needs_render = false
end

local function update_pref(key, value)
  if key == "brightness" then
    local number = tonumber(value)
    if number == nil then
      return false
    end
    if number < -2 then
      number = -2
    elseif number > 2 then
      number = 2
    end
    state.prefs.brightness = number
    return true
  end

  if key == "partials" then
    state.prefs.partials = value == "1"
    return true
  end

  if key == "position" then
    if VALID_POSITIONS[value] then
      state.prefs.position = value
      return true
    end
    return false
  end

  if key == "layout" then
    if VALID_LAYOUTS[value] then
      state.prefs.layout = value
      return true
    end
    return false
  end

  if key == "transcription_color" then
    if VALID_COLORS[value] then
      state.prefs.transcription_color = value
      return true
    end
    return false
  end

  if key == "translation_color" then
    if VALID_COLORS[value] then
      state.prefs.translation_color = value
      return true
    end
    return false
  end

  return false
end

local function apply_pref_payload(payload)
  local changed = false
  local pairs_list = split_text(payload, ";")
  for _, entry in ipairs(pairs_list) do
    local eq = string.find(entry, "=", 1, true)
    if eq ~= nil then
      local key = string.sub(entry, 1, eq - 1)
      local value = string.sub(entry, eq + 1)
      if update_pref(key, value) then
        changed = true
      end
    end
  end

  if changed then
    save_prefs()
    state.needs_render = true
    send_event({ "EVT", "PREFS_SAVED" })
  end
end

local function set_suggestion(index, text, phonetic)
  if index < 1 or index > 3 then
    return
  end
  state.suggestions[index] = {
    text = trim(text or ""),
    phonetic = trim(phonetic or ""),
  }
end

local function cycle_suggestions()
  local starting_index = state.suggestion_index
  for _ = 1, 3 do
    state.suggestion_index = state.suggestion_index + 1
    if state.suggestion_index > 3 then
      state.suggestion_index = 1
    end
    local suggestion = active_suggestion()
    if suggestion ~= nil then
      state.needs_render = true
      send_event({ "EVT", "SUGGESTION_INDEX", tostring(state.suggestion_index) })
      return
    end
  end
  state.suggestion_index = starting_index
end

local function clear_suggestions()
  for index = 1, 3 do
    state.suggestions[index] = { text = "", phonetic = "" }
  end
  state.suggestion_index = 1
  state.needs_render = true
end

local function set_connected(value)
  if state.connected ~= value then
    state.connected = value
    state.needs_render = true
  else
    state.connected = value
  end
end

local function set_mic_active(value)
  if state.mic_active ~= value then
    state.mic_active = value
    state.needs_render = true
  else
    state.mic_active = value
  end
end

local function set_mic_display(value)
  if state.mic_display_on ~= value then
    state.mic_display_on = value
    state.needs_render = true
  else
    state.mic_display_on = value
  end
end

local function safe_mic_start()
  local ok, err = pcall(frame.microphone.start, { sample_rate = 8000, bit_depth = 16 })
  if ok then
    state.audio_sequence = 0
    set_mic_active(true)
    set_mic_display(true)
    set_status("listening")
    return true
  end

  local message = tostring(err or "")
  if string.find(message, "already started", 1, true) ~= nil then
    set_mic_active(true)
    set_mic_display(true)
    set_status("listening")
    return true
  end

  set_status("error")
  send_event({ "EVT", "MIC_ERROR", message })
  return false
end

local function safe_mic_stop()
  local ok, err = pcall(frame.microphone.stop)
  if ok then
    set_mic_active(false)
    set_mic_display(false)
    set_status("idle")
    return true
  end

  local message = tostring(err or "")
  if string.find(message, "not started", 1, true) ~= nil then
    set_mic_active(false)
    set_mic_display(false)
    set_status("idle")
    return true
  end

  set_status("error")
  send_event({ "EVT", "MIC_ERROR", message })
  return false
end

local function handle_command(payload)
  local parts = split_text(payload, "\t")
  local command = parts[1]

  if command ~= nil then
    set_connected(true)
  end

  if command == "PING" then
    send_event({ "EVT", "READY", frame.FIRMWARE_VERSION, tostring(frame.bluetooth.max_length()) })
    return
  end

  if command == "SET_STATE" then
    set_status(parts[2] or "idle")
    return
  end

  if command == "SET_MIC" then
    set_mic_display(parts[2] == "1")
    return
  end

  if command == "SET_MODE" then
    state.mode = parts[2] or "translation"
    state.needs_render = true
    send_event({ "EVT", "MODE", state.mode })
    return
  end

  if command == "SET_PREFS" then
    apply_pref_payload(parts[2] or "")
    return
  end

  if command == "SHOW_CAPTION" then
    local caption_kind = parts[2] or "final"
    local text = parts[3] or ""
    if caption_kind == "partial" then
      state.partial_caption = trim(text)
      if not state.prefs.partials then
        state.partial_caption = ""
      end
    else
      state.final_caption = trim(text)
      if caption_kind == "final" then
        state.partial_caption = ""
      end
    end
    state.needs_render = true
    return
  end

  if command == "SHOW_TRANSCRIPT" then
    state.transcript_text = trim(parts[2] or "")
    state.needs_render = true
    return
  end

  if command == "CLEAR_CAPTION" then
    state.partial_caption = ""
    state.final_caption = ""
    state.transcript_text = ""
    state.needs_render = true
    return
  end

  if command == "SHOW_SUGGESTIONS" then
    clear_suggestions()
    local slot = 1
    for index = 2, #parts do
      if slot > 3 then
        break
      end
      local value_parts = split_text(parts[index], "~")
      set_suggestion(slot, value_parts[1] or "", value_parts[2] or "")
      slot = slot + 1
    end
    state.needs_render = true
    return
  end

  if command == "CLEAR_SUGGESTIONS" then
    clear_suggestions()
    return
  end

  if command == "CYCLE_SUGGESTIONS" then
    cycle_suggestions()
    return
  end

  if command == "MUTE" then
    state.muted = parts[2] == "1"
    state.needs_render = true
    return
  end

  if command == "MIC_START" then
    safe_mic_start()
    return
  end

  if command == "MIC_STOP" then
    safe_mic_stop()
    return
  end
end

local function bluetooth_receive(data)
  handle_command(data)
end

local function on_tap()
  local next_mic_state = not state.mic_active
  if next_mic_state then
    safe_mic_start()
  else
    safe_mic_stop()
  end
  send_event({ "EVT", "TAP", "toggle_listening", next_mic_state and "1" or "0" })
end

local function send_audio_chunk(data)
  local sequence = state.audio_sequence
  local packet = string.char(
    0x20,
    sequence % 256,
    math.floor(sequence / 256) % 256
  ) .. data

  while true do
    if pcall(frame.bluetooth.send, packet) then
      break
    end
  end

  state.audio_sequence = (sequence + 1) % 65536
end

local function run_app()
  state.prefs = load_prefs()
  frame.bluetooth.receive_callback(bluetooth_receive)
  frame.imu.tap_callback(on_tap)
  frame.display.set_brightness(state.prefs.brightness)
  set_connected(false)
  set_mic_display(false)
  set_mic_active(false)
  set_status("disconnected")
  send_event({ "EVT", "BOOT", frame.FIRMWARE_VERSION, tostring(frame.bluetooth.max_length()) })

  local max_audio_bytes = frame.bluetooth.max_length() - 3
  if max_audio_bytes % 2 == 1 then
    max_audio_bytes = max_audio_bytes - 1
  end
  if max_audio_bytes < 64 then
    max_audio_bytes = 64
  end

  while true do
    if state.needs_render then
      render_ui()
    end

    if state.mic_active then
      for _ = 1, 8 do
        local audio = frame.microphone.read(max_audio_bytes)
        if audio == nil then
          set_mic_display(false)
          set_mic_active(false)
          set_status("idle")
          break
        elseif audio ~= "" then
          send_audio_chunk(audio)
          frame.sleep(0.0025)
        end
      end
    else
      frame.sleep(0.02)
    end
  end
end

local ok, err = xpcall(run_app, debug.traceback)
if not ok then
  save_crash(err)
  show_crash(err)
  while true do
    frame.sleep(1)
  end
end
"""#
}
