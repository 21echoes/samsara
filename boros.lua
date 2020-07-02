-- Boros
-- A simple looper,
--  inspired by Dakim
--
-- E1: Number of beats
-- K2+E1: Tempo
-- E2: Loop preserve rate
-- E3: Rec. mode (loop/one-shot)
-- K2: Start/pause
-- K3: Arm/disarm recording
-- Hold K2+tap K3: Tap tempo
-- Hold K1+tap K2: Double buffer
-- Hold K1+tap K3: Clear buffer

local ControlSpec = require "controlspec"
local TapTempo = include("lib/tap_tempo")

local playing = 1
local rec_level = 1.0
local prior_record_mode = 1
local one_shot_metro
local tap_tempo = TapTempo.new()
local loop_dur
local held_key
local modified_level_params = {
  "cut_input_adc",
  "cut_input_eng",
  "cut_input_tape",
  "monitor_level",
  "softcut_level"
}
local initial_levels = {}
local MAX_NUM_BEATS = 64

function init()
  init_params()
  init_softcut()
end

function init_params()
  params:add_separator()
  params:add {
    id="pre_level",
    name="Feedback",
    type="control",
    controlspec=ControlSpec.new(0, 1, "lin", 0, 0.95, ""),
    action=function(value) set_pre_level(value) end
  }
  params:add {
    id="num_beats",
    name="Num Beats",
    type="number",
    min=1,
    max=MAX_NUM_BEATS,
    default=8,
    action=function(value) set_num_beats(value) end
  }
  params:add {
    id="record_mode",
    name="Recording Mode",
    type="option",
    options={"Continuous", "One-Shot"},
    default=1,
    action=function(value) set_record_mode(value) end
  }
  params:add {
    id="num_input_channels",
    name="Input Mode",
    type="option",
    options={"Mono", "Stereo"},
    default=(params:get("monitor_mode") == 1 and 2 or 1),
    action=function(value) set_num_input_channels(value) end
  }
  local default_tempo_action = params:lookup_param("clock_tempo").action
  params:set_action("clock_tempo", function(value)
    default_tempo_action(value)
    set_tempo(value)
  end)
  params:bang()
end

function init_softcut()
  -- Set up default levels
  for i, level_param in ipairs(modified_level_params) do
    initial_levels[level_param] = params:get(level_param)
    -- Setting 0 as it's in dBs and 0 dB is unity gain / amp of 1
    -- TODO: confirm this does what you want
    params:set(level_param, 0)
  end

  softcut.buffer_clear()

  for voice=1,2 do
    softcut.enable(voice, 1)
    softcut.buffer(voice, voice)
    softcut.level(voice, 1.0)
    softcut.pan(voice, voice == 1 and -1.0 or 1.0)
    softcut.rate(voice, 1)
    softcut.loop(voice, 1)
    softcut.loop_start(voice, 0)
    softcut.position(voice, 0)
    softcut.level_input_cut(voice, voice, 1.0)
    softcut.rec_level(voice, rec_level)
    softcut.rec(voice, 1)
  end
  for voice=1,2 do
    softcut.play(voice, playing)
  end
end

function enc(n, delta)
  if n==1 then
    -- We're using tap_tempo:is_in_tap_tempo_mode as our general "alt mode"
    if tap_tempo:is_in_tap_tempo_mode() and params:get("clock_source") == 1 then
      params:delta("clock_tempo", delta)
    else
      params:delta("num_beats", delta)
    end
  elseif n==2 then
    local pre_level = params:get("pre_level")
    if pre_level >= 0.9 then
      delta = delta/2
    end
    params:delta("pre_level", delta)
  elseif n==3 then
    params:delta("record_mode", delta)
  end
  redraw()
end

local just_doubled_buffer = false
function key(n, z)
  if z == 1 then
    if held_key == nil then
      held_key = n
    elseif held_key == 1 and n == 2 then
      just_doubled_buffer = true
      if num_beats < MAX_NUM_BEATS then
        double_buffer()
      end
      redraw()
      return
    elseif held_key == 1 and n == 3 then
      softcut.buffer_clear()
      redraw()
      return
    end
  elseif held_key == n and z == 0 then
    held_key = nil
  end

  -- Hold K2 + Tap K3 means tap tempo
  local tempo, short_circuit_value = tap_tempo:key(n, z)
  if tempo and params:get("clock_source") == 1 then
    params:set("clock_tempo", tempo)
  end
  if short_circuit_value ~= nil then
    redraw()
    return short_circuit_value
  end

  -- For K2 we listen to key-up (key-down starts alt mode)
  if n==2 and z==0 then
    if just_doubled_buffer then
      just_doubled_buffer = false
      return
    end
    if playing == 1 then
      set_playing(0)
    else
      set_playing(1)
    end
  elseif n==3 and z==1 then
    -- K3 means toggle recording on/off
    if rec_level == 1.0 then
      -- Even if we're not in one-shot, this stops recording
      one_shot_stop()
    else
      if params:get("record_mode") == 1 then
        set_rec_level(1.0)
      else
        one_shot_start()
      end
    end
  end
  -- TOOD: UI update metro
  redraw()
end

function clock.transport.start()
  set_playing(1)
end

function clock.transport.stop()
  set_playing(0)
end

function redraw()
  screen.clear()

  local left_x = 10
  local right_x = 118
  local y = 12
  screen.move(left_x, y)
  screen.text("length: ")
  screen.move(right_x, y)
  local tempo = params:get("clock_tempo")
  local num_beats = params:get("num_beats")
  screen.text_right(num_beats.." beats, "..math.floor(tempo+0.5).." bpm")

  y = 27
  screen.move(left_x, y)
  screen.text("preserve: ")
  screen.move(right_x, y)
  local pre_level = params:get("pre_level")
  if pre_level >= 0.9 then
    screen.text_right(string.format("%.1f", pre_level * 100).."%")
  else
    screen.text_right(string.format("%.0f", pre_level * 100).."%")
  end

  y = 42
  screen.move(left_x, y)
  screen.text("mode: ")
  screen.move(right_x, y)
  local record_mode = params:get("record_mode")
  screen.text_right(record_mode == 1 and "continuous" or "one-shot")

  y = 57
  screen.move(left_x, y)
  if playing == 1 then
    screen.text("playing")
  else
    screen.text("paused")
  end
  screen.move(right_x, y)
  if rec_level == 1.0 then
    screen.text_right("recording")
  else
    screen.text_right("not recording")
  end

  screen.update()
end

function set_playing(value)
  playing = value
  for voice=1,2 do
    if playing == 0 then
      softcut.rec_level(voice, 0.0)
      softcut.level(voice, 0.0)
    else
      softcut.rec_level(voice, rec_level)
      softcut.level(voice, 1.0)
    end
    softcut.enable(voice, playing)
  end
end

function set_rec_level(value)
  rec_level = value
  for voice=1,2 do
    softcut.rec_level(voice, rec_level)
    -- TODO: if you want rec_level == 0 to turn off deterioration:
    -- softcut.pre_level(voice, rec_level == 0.0 and 1.0 or params:get("pre_level"))
  end
end

function set_pre_level(pre_level)
  for voice=1,2 do
    -- We set both level and pre-level,
    -- because we want both real-time manipulation
    -- *and* to write that manipulation to the buffer
    --
    -- TODO: confirm this is really how it works
    -- (when head passes over sample, it first plays it back,
    --  then modifies its level in the buffer)
    softcut.level(voice, pre_level)
    softcut.pre_level(voice, pre_level)
  end
end

function set_num_beats(num_beats)
  local tempo = params:get("clock_tempo")
  set_loop_dur(tempo, num_beats)
end

function set_tempo(tempo)
  local num_beats = params:get("num_beats")
  set_loop_dur(tempo, num_beats)
end

function set_loop_dur(tempo, num_beats)
  loop_dur = (num_beats/tempo) * 60
  for voice=1,2 do
    softcut.loop_end(voice, loop_dur)
  end
  -- TODO: should we clear the buffer outside the loop, now? if not now, ever?
end

function set_record_mode(value)
  local record_mode = value
  if value == "Continuous" then record_mode = 1 elseif value == "One-Shot" then record_mode = 2 end
  if rec_level == 1.0 and record_mode ~= prior_record_mode then
    if record_mode == 1 and one_shot_metro then
      metro.free(one_shot_metro.id)
      one_shot_metro = nil
    else
      one_shot_start()
    end
  end
  prior_record_mode = record_mode
end

function one_shot_start()
  set_rec_level(1.0)
  one_shot_metro = metro.init(one_shot_stop, loop_dur, 1)
  one_shot_metro:start()
end

function one_shot_stop()
  set_rec_level(0.0)
  if one_shot_metro then
    metro.free(one_shot_metro.id)
    one_shot_metro = nil
  end
  redraw()
end

function set_num_input_channels(value)
  local coerced_value = value
  if value == "Stereo" then coerced_value = 2 elseif value == "Mono" then coerced_value = 1 end
  if value == 2 then
    softcut.level_input_cut(1, 1, 1.0)
    softcut.level_input_cut(1, 2, 0.0)
    softcut.level_input_cut(2, 1, 0.0)
    softcut.level_input_cut(2, 2, 1.0)
  else
    softcut.level_input_cut(1, 1, 1.0)
    softcut.level_input_cut(1, 2, 1.0)
    softcut.level_input_cut(2, 1, 0.0)
    softcut.level_input_cut(2, 2, 0.0)
  end
end

function cleanup()
  if one_shot_metro then
    metro.free(one_shot_metro.id)
    one_shot_metro = nil
  end
  tap_tempo = nil

  -- Restore prior levels
  for level_param, level in ipairs(initial_levels) do
    params:set(level_param, level)
  end
  modified_level_params = nil
  initial_levels = nil
end

function double_buffer()
  -- Duplicate the buffer immediately after the current buffer ends
  local full_path = "/home/we/dust/code/boros/boros-tmp.wav"
  softcut.buffer_write_stereo(full_path, 0, loop_dur)
  softcut.buffer_read_stereo(full_path, 0, loop_dur, loop_dur)
  local num_beats = params:get("num_beats")
  params:set("num_beats", num_beats * 2)
  -- Sleep is there because it takes a bit for the file system to recognize the file exists
  -- Also, os.remove doesn't work...
  os.execute("sleep 0.2; rm "..full_path)
end
