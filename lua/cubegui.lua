-- cubegui.lua: decides who drives the servos: CubeGUI, the RC transmitter,
-- or a controller that holds the fuselage's pitch.
--
-- Put it in APM/scripts on the Cube's SD card, set SCR_ENABLE = 1 and
-- reboot. lua/README.md in CubeGUI explains how to set it up.
--
-- How it works, in short:
--   * Every servo stays on SERVOn_FUNCTION = 0. In GUI mode this script does
--     nothing, and CubeGUI's slider commands drive the servos as usual.
--   * In RC mode, it copies the transmitter's sticks onto the outputs.
--   * In closed-loop mode, a PID controller moves the elevator to hold the
--     pitch at a target sent from CubeGUI.
--   * A transmitter switch with RCn_OPTION = 300 chooses: low RC, high
--     CubeGUI, middle no change (the same as the guide's avdasi2.lua).
--     Another with RCn_OPTION = 301 switches SAS. Without them, CubeGUI chooses.
--   * While this script drives an output, the Cube ignores CubeGUI's
--     commands to that output, so only one thing drives a servo at a time.
--   * It tells CubeGUI what it's doing, 5 times a second, as named values:
--     CG_MODE (0 GUI, 1 RC, 2 closed loop), CG_SAS, CG_TGT, CG_RC, CG_ELEV.
--
-- Needs ArduPlane 4.5 or later (for receiving CubeGUI's commands).

local PARAM_TABLE_KEY = 72      -- must differ from every other script's (servo_slew.lua uses 135)
local PARAM_PREFIX = "CGUI_"
local UPDATE_MS = 20            -- run 50 times a second
local REPORT_EVERY = 10         -- report to CubeGUI every 10th run: 5 times a second
local LOG_EVERY = 5             -- write to the Cube's own log every 5th run: 10 times a second
local OVERRIDE_MS = 100         -- each output we drive is ours for this long, unless renewed
local MAV_CMD_USER_1 = 31010    -- the command CubeGUI sends us
local COMMAND_LONG_ID = 76

local MODE_GUI = 0
local MODE_RC = 1
local MODE_CLOSED_LOOP = 2

-- ---- Parameters, editable in CubeGUI's Setup tab or Mission Planner --------

assert(param:add_table(PARAM_TABLE_KEY, PARAM_PREFIX, 20), "cubegui.lua: couldn't add its parameter table")

local function addParam(index, name, default)
  assert(param:add_param(PARAM_TABLE_KEY, index, name, default),
         "cubegui.lua: couldn't add " .. PARAM_PREFIX .. name)
  local p = Parameter()
  assert(p:init(PARAM_PREFIX .. name), "cubegui.lua: couldn't find " .. PARAM_PREFIX .. name)
  return p
end

local ENABLE   = addParam(1, "ENABLE", 1)      -- 0: drive nothing, leave everything to CubeGUI
local ELEV_OUT = addParam(2, "ELEV_OUT", 5)    -- the elevator's output (MAIN OUT 5 is 5)
-- (Indices 3 and 4 were MODE_CH and SAS_CH: don't reuse them.)
local KP       = addParam(5, "KP", 10)         -- us of elevator per degree of pitch error
local KI       = addParam(6, "KI", 2)          -- us per degree-second of error
local KD       = addParam(7, "KD", 3)          -- us per degree/second of pitch rate
local IMAX     = addParam(8, "IMAX", 150)      -- the most the I term may add, in us
local SAS_KD   = addParam(9, "SAS_KD", 3)      -- SAS pitch damping in RC mode, us per degree/second
-- In RC mode, stick n drives output n. Up to four pairs; 0 means unused.
local STICKS = {
  {rc = addParam(10, "M1_RC", 2), out = addParam(11, "M1_OUT", 5)},   -- elevator stick -> MAIN OUT 5
  {rc = addParam(12, "M2_RC", 4), out = addParam(13, "M2_OUT", 6)},   -- rudder stick -> MAIN OUT 6
  {rc = addParam(14, "M3_RC", 0), out = addParam(15, "M3_OUT", 0)},
  {rc = addParam(16, "M4_RC", 0), out = addParam(17, "M4_OUT", 0)},
}
-- The switches are found by their RCn_OPTION, as in the guide's avdasi2.lua:
-- set RCn_OPTION = 300 on the mode switch's channel and 301 on the SAS switch's.
local MODE_FUNC = addParam(18, "MODE_FUNC", 300)   -- RCn_OPTION of the mode switch (300 = Scripting1)
local SAS_FUNC  = addParam(19, "SAS_FUNC", 301)    -- RCn_OPTION of the SAS switch (301 = Scripting2)

-- ---- Receiving CubeGUI's commands --------------------------------------------

-- Both numbers the same: their order differs between ArduPlane versions.
mavlink:init(4, 4)
mavlink:register_rx_msgid(COMMAND_LONG_ID)
mavlink:block_command(MAV_CMD_USER_1)   -- ours: stop ArduPilot answering "unsupported"

local guiMode = MODE_GUI    -- what CubeGUI last asked for: GUI or closed loop
local guiTarget = 0         -- pitch target from CubeGUI, degrees
local guiSas = false        -- SAS on or off, from CubeGUI

local function readCubeGuiCommands()
  local msg = mavlink:receive_chan()
  while msg do
    -- msg is MAVLink's own message structure: 12 bytes of header, then the
    -- payload. MAVLink 2 leaves off trailing zero bytes, so put them back.
    local payload = string.sub(msg, 13) .. string.rep("\0", 33)
    local p1, p2, p3, _, _, _, _, command = string.unpack("<fffffffI2", payload)
    if command == MAV_CMD_USER_1 then
      guiMode = (math.floor(p1 + 0.5) == MODE_CLOSED_LOOP) and MODE_CLOSED_LOOP or MODE_GUI
      guiTarget = math.max(-45, math.min(45, p2))   -- never ask for more than 45 degrees
      guiSas = p3 > 0.5
    end
    msg = mavlink:receive_chan()
  end
end

-- ---- The transmitter -----------------------------------------------------------

-- A switch's position: 0 low, 1 middle, 2 high, or nil if no channel has
-- that RCn_OPTION or there's no valid RC. The position is read now, with
-- ArduPilot's own thresholds (below 1200 low, above 1800 high), so it's
-- right from boot without the switch having to move first.
-- rc:has_valid_input() turns false when the Cube declares RC lost, which
-- needs THR_FAILSAFE = 1 or 2 (2 is best here).
local function switchPosition(option)
  if option <= 0 or not rc:has_valid_input() then
    return nil
  end
  local channel = rc:find_channel_for_option(option)
  if not channel then
    return nil
  end
  return channel:get_aux_switch_pos()
end

-- ---- Servo outputs -------------------------------------------------------------

-- An output's limits and direction, from the same parameters CubeGUI uses.
local function outputInfo(out)
  local reversed = param:get(string.format("SERVO%d_REVERSED", out)) or 0
  return {
    min = param:get(string.format("SERVO%d_MIN", out)) or 1100,
    trim = param:get(string.format("SERVO%d_TRIM", out)) or 1500,
    max = param:get(string.format("SERVO%d_MAX", out)) or 1900,
    dir = (reversed > 0.5) and -1 or 1,   -- -1 swaps which way is "up"
  }
end

-- Send pwm to output out, held within its limits. Returns the PWM sent.
local function drive(out, pwm)
  local info = outputInfo(out)
  pwm = math.floor(math.max(info.min, math.min(info.max, pwm)) + 0.5)
  SRV_Channels:set_output_pwm_chan_timeout(out - 1, pwm, OVERRIDE_MS)
  return pwm
end

-- The PWM for a position from -1 to 1 ("up" positive): 0 is TRIM, 1 is MAX
-- and -1 is MIN, after any reversing, like CubeGUI's percent.
local function pwmForPosition(out, position)
  local info = outputInfo(out)
  local p = info.dir * position
  if p >= 0 then
    return info.trim + p * (info.max - info.trim)
  end
  return info.trim + p * (info.trim - info.min)
end

-- The PWM for trim plus an offset in us ("up" positive), after any reversing.
local function pwmForOffset(out, offset)
  local info = outputInfo(out)
  return info.trim + info.dir * offset
end

-- A stick's position as -1 to 1, from the transmitter's calibration, or nil.
local function stick(channel)
  local ch = rc:get_channel(channel)
  if not ch then
    return nil
  end
  return ch:norm_input()
end

-- ---- The pitch controller -------------------------------------------------------

local integral = 0       -- the I term, in us
local lastP, lastD = 0, 0

local function closedLoopOffset(target, pitch, rate, dt)
  local err = target - pitch
  lastP = KP:get() * err
  lastD = -KD:get() * rate                 -- damping: oppose the pitch rate
  local limit = IMAX:get()
  integral = math.max(-limit, math.min(limit, integral + KI:get() * err * dt))
  return lastP + integral + lastD
end

-- ---- The main loop ----------------------------------------------------------------

-- Newer ArduPlane calls it get_pitch_rad and warns about get_pitch; 4.6 only
-- has get_pitch. Use whichever this Cube has.
local getPitch = ahrs.get_pitch_rad or ahrs.get_pitch

local count = 0
local mode = MODE_GUI
local elevPwm = 0
local switchSaysRc = false   -- the mode switch's last low or high position
local switchSas = nil        -- the SAS switch's last low or high position (nil: no switch)

local function update()
  readCubeGuiCommands()
  count = count + 1

  local pitch = math.deg(getPitch(ahrs))              -- degrees, nose up positive
  local rate = math.deg(ahrs:get_gyro():y())           -- degrees per second

  -- Who's in charge? The mode switch: low RC, high CubeGUI (which may ask
  -- for the closed loop), middle no change. No switch or no RC: CubeGUI.
  local position = switchPosition(math.floor(MODE_FUNC:get()))
  if position == 0 then
    switchSaysRc = true
  elseif position == 2 or position == nil then
    switchSaysRc = false
  end
  local newMode = switchSaysRc and MODE_RC or guiMode
  if ENABLE:get() < 0.5 then
    newMode = MODE_GUI
  end
  if newMode ~= mode then
    integral = 0     -- start the controller afresh
    mode = newMode
  end

  -- SAS: the SAS switch (low off, high on, middle no change), else CubeGUI.
  local sasPosition = switchPosition(math.floor(SAS_FUNC:get()))
  if sasPosition == 0 then
    switchSas = false
  elseif sasPosition == 2 then
    switchSas = true
  elseif sasPosition == nil then
    switchSas = nil
  end
  local sas = guiSas
  if switchSas ~= nil then
    sas = switchSas
  end

  local elevOut = math.floor(ELEV_OUT:get())
  elevPwm = 0
  if mode == MODE_RC then
    for _, pair in ipairs(STICKS) do
      local channel, out = math.floor(pair.rc:get()), math.floor(pair.out:get())
      local position = (channel > 0 and out > 0) and stick(channel) or nil
      if position then
        local pwm = pwmForPosition(out, position)
        if sas and out == elevOut then
          pwm = pwm + outputInfo(out).dir * (-SAS_KD:get() * rate)   -- add pitch damping
        end
        pwm = drive(out, pwm)
        if out == elevOut then
          elevPwm = pwm
        end
      end
    end
  elseif mode == MODE_CLOSED_LOOP then
    elevPwm = drive(elevOut, pwmForOffset(elevOut, closedLoopOffset(guiTarget, pitch, rate, UPDATE_MS / 1000)))
  end

  if count % REPORT_EVERY == 0 then
    gcs:send_named_float("CG_MODE", mode)
    gcs:send_named_float("CG_SAS", sas and 1 or 0)
    gcs:send_named_float("CG_TGT", guiTarget)
    gcs:send_named_float("CG_RC", rc:has_valid_input() and 1 or 0)
    gcs:send_named_float("CG_ELEV", elevPwm)
  end
  if count % LOG_EVERY == 0 then
    -- Into the Cube's own log, as CGUI: everything needed to study the controller afterwards.
    logger:write("CGUI", "Mode,SAS,Tgt,Pitch,Rate,P,I,D,Elev", "BBffffffH",
                 mode, sas and 1 or 0, guiTarget, pitch, rate, lastP, integral, lastD, elevPwm)
  end
  return update, UPDATE_MS
end

-- If anything goes wrong, say so and try again in a second, rather than stop.
local function protected()
  local ok, err = pcall(update)
  if not ok then
    gcs:send_text(3, "cubegui.lua: " .. tostring(err))
    return protected, 1000
  end
  return protected, UPDATE_MS
end

gcs:send_text(6, "cubegui.lua running")
return protected, 1000
