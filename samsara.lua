-- Samsara
-- A simple looper
--  where sounds slowly decay
--
-- E1: Number of beats
-- Hold K2+turn E1: Tempo
-- E2: Loop preserve rate
-- E3: Rec. mode (loop/one-shot)
-- Hold K2+turn E3: Click (on/off)
-- K2: Start/pause playback
-- K3: Arm/disarm recording
-- Hold K2+tap K3: Tap tempo
-- Hold K1+tap K2: Double buffer
-- Hold K1+tap K3: Clear buffer
--
-- v1.1.0 @21echoes

local ControlSpec = require "controlspec"
local TapTempo = include("lib/tap_tempo")
local Alert = include("lib/alert")

-- Use the PolyPerc engine for the click track
engine.name = 'PolyPerc'

local playing = 1
local rec_level = 1.0
local prior_record_mode = 1
local one_shot_metro
local tap_tempo = TapTempo.new()
local tap_tempo_square
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
local SCREEN_FRAMERATE = 15
local screen_refresh_metro
local is_screen_dirty = false
local ext_clock_alert
local ext_clock_alert_dismiss_metro
local clear_confirm
local click_track_square

-- Initialization
function init()
  init_params()
  init_softcut()
  init_ui_metro()
  init_click_track()
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
  params:add {
    id="click_track_enabled",
    name="Click Track",
    type="option",
    options={"Disabled", "Enabled"},
    default=1,
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
    if level_param == "cut_input_eng" then
      -- The click track uses the engine, and we don't want to record the click track to the loop
      params:set("cut_input_eng", -math.huge)
    else
      params:set(level_param, 0)
    end
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

function init_ui_metro()
  -- Render loop
  screen_refresh_metro = metro.init()
  screen_refresh_metro.event = screen_frame_tick
  screen_refresh_metro:start(1 / SCREEN_FRAMERATE)
end

function init_click_track()
  softcut.event_phase(click)
  softcut.poll_start_phase()
end

-- Interaction hooks
function enc(n, delta)
  if n==1 then
    -- We're using tap_tempo:is_in_tap_tempo_mode as our general "alt mode"
    if tap_tempo:is_in_tap_tempo_mode() then
      if params:get("clock_source") == 1 then
        params:delta("clock_tempo", delta)
      else
        show_ext_clock_alert()
      end
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
    -- We're using tap_tempo:is_in_tap_tempo_mode as our general "alt mode"
    if tap_tempo:is_in_tap_tempo_mode() then
      params:delta("click_track_enabled", delta)
    else
      params:delta("record_mode", delta)
    end
  end
end

local just_doubled_buffer = false
function key(n, z)
  -- Any keypress that is not K3 while showing the clear confirm dialog dismisses the dialog
  if clear_confirm ~= nil and n ~= 3 then
    clear_confirm = nil
    is_screen_dirty = true
  end

  if z == 1 then
    if held_key == nil then
      held_key = n
    elseif held_key == 1 and n == 2 then
      just_doubled_buffer = true
      if params:get("num_beats") < MAX_NUM_BEATS then
        double_buffer()
      end
      return
    elseif held_key == 1 and n == 3 then
      if ext_clock_alert == nil then
        if clear_confirm ~= nil then
          softcut.buffer_clear()
          clear_confirm = nil
        else
          clear_confirm = Alert.new({"Continue holding K1", "and press K3 again", "to erase everything"})
        end
        is_screen_dirty = true
      end
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
    if n == 3 and z == 1 then
      if params:get("clock_source") == 1 then
        tap_tempo_square = util.time()
        is_screen_dirty = true
      else
        show_ext_clock_alert()
      end
    end
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
end

-- Clock hooks
function clock.transport.start()
  set_playing(1)
end

function clock.transport.stop()
  set_playing(0)
end

-- Metro / Clock callbacks
function play_click(voice, position)
  -- Trigger for softcut voice 1 only, only if enabled, and only if not currently tapping tempo
  local should_trigger = voice == 1 and params:get("click_track_enabled") == 2 and not tap_tempo._tap_tempo_used
  if should_trigger then
    local is_smearing = false
    if click_track_square ~= nil then
      -- While the user is adjusting the tempo, we can get click track "smears"
      -- as the phase callback triggers for two different quanta in quick succession
      local time_since_last_click = util.time() - click_track_square
      local beat_dur = (60 / params:get("clock_tempo"))
      is_smearing = time_since_last_click < (beat_dur * 0.5)
    end
    if not is_smearing then
      engine.hz(523.25)
    end
    click_track_square = util.time()
    is_screen_dirty = true
  end
end

function screen_frame_tick()
  if is_screen_dirty then
    is_screen_dirty = false
    redraw()
  end
end

function redraw()
  screen.clear()

  if ext_clock_alert ~= nil then
    ext_clock_alert:redraw()
    screen.update()
    return
  end

  if clear_confirm ~= nil then
    clear_confirm:redraw()
    screen.update()
    return
  end

  local left_x = 10
  local right_x = 118
  local y = 12
  screen.move(left_x, y)
  screen.text("length: ")
  screen.move(right_x, y)
  local tempo = params:get("clock_tempo")
  local num_beats = params:get("num_beats")
  screen.text_right(num_beats.." beats, "..math.floor(tempo+0.5).." bpm")

  if tap_tempo_square ~= nil then
    if (util.time() - tap_tempo_square) < 0.125 then
      screen.rect(122, 8, 4, 4)
      screen.fill()
      is_screen_dirty = true
    else
      tap_tempo_square = nil
    end
  elseif click_track_square ~= nil then
    if (util.time() - click_track_square) < 0.125 then
      screen.rect(122, 8, 4, 4)
      screen.fill()
      is_screen_dirty = true
    else
      click_track_square = nil
    end
  end

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
  screen.text("rec mode: ")
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

function show_ext_clock_alert()
  if ext_clock_alert ~= nil then
    return
  end
  local source = ({"", "MIDI", "Link", "crow"})[params:get("clock_source")]
  ext_clock_alert = Alert.new({"Tempo is following "..source, "", "Use params menu to change", "your clock settings"})
  ext_clock_alert_dismiss_metro = metro.init(dismiss_ext_clock_alert, 2, 1)
  ext_clock_alert_dismiss_metro:start()
  is_screen_dirty = true
end

function dismiss_ext_clock_alert()
  ext_clock_alert = nil
  if ext_clock_alert_dismiss_metro then
    metro.free(ext_clock_alert_dismiss_metro.id)
    ext_clock_alert_dismiss_metro = nil
  end
  is_screen_dirty = true
end

-- Setters
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
  is_screen_dirty = true
end

function set_rec_level(value)
  rec_level = value
  for voice=1,2 do
    softcut.rec_level(voice, rec_level)
    -- TODO: if you want rec_level == 0 to turn off deterioration:
    -- softcut.pre_level(voice, rec_level == 0.0 and 1.0 or params:get("pre_level"))
  end
  is_screen_dirty = true
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
  is_screen_dirty = true
end

function set_num_beats(num_beats)
  local tempo = params:get("clock_tempo")
  set_loop_dur(tempo, num_beats)
end

function set_tempo(tempo)
  local num_beats = params:get("num_beats")
  set_loop_dur(tempo, num_beats)

  -- Set up the click track callback to line up with the tempo
  local beat_dur = (60 / tempo)
  for voice=1,2 do
    softcut.phase_quant(voice, beat_dur)
  end
end

function set_loop_dur(tempo, num_beats)
  loop_dur = (num_beats/tempo) * 60
  for voice=1,2 do
    softcut.loop_end(voice, loop_dur)
  end
  -- TODO: should we clear the buffer outside the loop, now? if not now, ever?
  is_screen_dirty = true
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
  is_screen_dirty = true
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
end

function set_num_input_channels(value)
  local coerced_value = value
  if value == "Stereo" then coerced_value = 2 elseif value == "Mono" then coerced_value = 1 end
  if coerced_value == 2 then
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

function double_buffer()
  -- Duplicate the buffer immediately after the current buffer ends
  local full_path = "/home/we/dust/code/samsara/tmp.wav"
  -- Write an additional second to disk to get nice cross-fade behavior
  softcut.buffer_write_stereo(full_path, 0, loop_dur + 1)
  softcut.buffer_read_stereo(full_path, 0, loop_dur, loop_dur + 1)
  local num_beats = params:get("num_beats")
  params:set("num_beats", num_beats * 2)
  -- Sleep is there because it takes a bit for the file system to recognize the file exists
  -- Also, os.remove doesn't work...
  os.execute("sleep 0.2; rm "..full_path)
end

-- Cleanup
function cleanup()
  if screen_refresh_metro then
    metro.free(screen_refresh_metro.id)
    screen_refresh_metro = nil
  end
  if one_shot_metro then
    metro.free(one_shot_metro.id)
    one_shot_metro = nil
  end
  if ext_clock_alert_dismiss_metro then
    metro.free(ext_clock_alert_dismiss_metro.id)
    ext_clock_alert_dismiss_metro = nil
  end
  tap_tempo = nil
  ext_clock_alert = nil
  clear_confirm = nil

  -- Restore prior levels
  for level_param, level in ipairs(initial_levels) do
    params:set(level_param, level)
  end
  modified_level_params = nil
  initial_levels = nil
  softcut.poll_stop_phase()
end
