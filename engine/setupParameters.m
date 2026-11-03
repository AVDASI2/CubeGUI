function params = setupParameters(servos, extraNames, level)
%SETUPPARAMETERS  The Cube parameters shown in the Setup tab, grouped, with notes.
%
%   Part of CubeGUI's engine. To show another parameter, add its name to
%   "extraParams" under "setup" in the settings file instead.
%
%   params = setupParameters(config.servos, config.setup.extraParams, config.level)
%
%   Not the full parameter list (a Cube has over a thousand): just the ones
%   that matter at this capability level. Each level shows its own and the
%   ones below it. Each entry has:
%     level     the first level it appears at
%     group     a heading, so related parameters sit together
%     name      the parameter's name on the Cube
%     wanted    the value CubeGUI needs, or NaN if any value is fine
%     isOk      a function: isOk(value) is true if the current value is fine
%     readOnly  true for parameters CubeGUI shows but won't let you change
%     why       a plain-English note, shown in the table
%
%   extraNames adds more parameters by name (from the settings file), under
%   "Your parameters", at every level.

if nargin < 2
    extraNames = strings(1, 0);
end
if nargin < 3
    level = 3;
end
params = struct("level", {}, "group", {}, "name", {}, "wanted", {}, "isOk", {}, ...
    "readOnly", {}, "why", {});
anyValue = @(v) true;

% ---- Level 1: what CubeGUI needs to drive the servos ---------------------------
g = "Needed by CubeGUI";
% DO_SET_SERVO only works on an output whose function is 0 (Disabled),
% 1 (RCPassThru) or 51 to 66 (RCIN1 to RCIN16).
free = @(v) v == 0 || v == 1 || (v >= 51 && v <= 66);
for s = reshape(servos, 1, [])
    params(end+1) = entry(1, g, sprintf("SERVO%d_FUNCTION", s.output), 0, free, false, ...
        sprintf("0 frees output %d for CubeGUI to drive the %s.", s.output, lower(s.name))); %#ok<AGROW>
end

% CubeGUI uses MIN, TRIM and MAX as each servo's limits: percent on the
% slider is worked out from them, and nothing outside MIN to MAX is sent.
% Anything outside 1000 to 2000 us is refused.
inRange = @(v) v >= DataSource.HardMinPwm && v <= DataSource.HardMaxPwm;
for s = reshape(servos, 1, [])
    g = sprintf("Output %d (%s)", s.output, s.name);
    n = s.output;
    params(end+1) = entry(1, g, sprintf("SERVO%d_MIN", n), NaN, inRange, false, ...
        "Lowest PWM for this servo: -100 % on the slider. CubeGUI never sends less. 1000 to 2000."); %#ok<AGROW>
    params(end+1) = entry(1, g, sprintf("SERVO%d_TRIM", n), NaN, inRange, false, ...
        "Centre PWM: 0 % on the slider, and where Zero all sends it. Between MIN and MAX."); %#ok<AGROW>
    params(end+1) = entry(1, g, sprintf("SERVO%d_MAX", n), NaN, inRange, false, ...
        "Highest PWM for this servo: +100 % on the slider. CubeGUI never sends more. 1000 to 2000."); %#ok<AGROW>
    params(end+1) = entry(1, g, sprintf("SERVO%d_REVERSED", n), NaN, anyValue, false, ...
        "1 reverses the output when the Cube itself drives it, from RC say. It doesn't reverse CubeGUI's slider."); %#ok<AGROW>
end

g = "Safety";
params(end+1) = entry(1, g, "BRD_SAFETY_DEFLT", NaN, anyValue, false, ...
    "1: the safety switch is on after every reboot. Changing it needs a reboot.");
% THR_FAILSAFE doesn't matter for CubeGUI's servos below level 2: a
% disarmed Plane that has never heard an RC receiver skips the RC failsafe
% check (ArduPlane's radio.cpp, allow_failsafe_bypass), and a failsafe only
% changes the flight mode, not outputs with function 0. The guide sets 0
% so the Cube can be armed without RC. From level 2 there's a receiver, and
% with 0 the Cube never declares RC lost, so cubegui.lua would carry on with
% the last stick positions. 2 detects the loss and stops RC being used,
% without a failsafe action (Parameters.cpp, RC_Channel_Plane.cpp).
if level >= 2
    params(end+1) = entry(1, g, "THR_FAILSAFE", 2, @(v) v == 1 || v == 2, false, ...
        "2 lets the Cube notice if the transmitter's signal is lost, so cubegui.lua stops using the sticks. It doesn't arm or change mode.");
else
    params(end+1) = entry(1, g, "THR_FAILSAFE", NaN, anyValue, false, ...
        "RC failsafe. Any value is fine for CubeGUI, which never arms the Cube. The guide sets 0, which only matters for arming without an RC receiver.");
end

g = "Telemetry link (TELEM1)";
params(end+1) = entry(1, g, "SERIAL1_PROTOCOL", NaN, anyValue, true, ...
    "2 is MAVLink 2, which the Kahuna needs. Read-only here: change it over USB in Mission Planner.");
params(end+1) = entry(1, g, "SERIAL1_BAUD", NaN, anyValue, true, ...
    "57 means 57600 baud, the Kahuna's speed. Read-only here, for the same reason.");

% ---- Level 1: logging and Lua scripts ------------------------------------------
g = "Logging and scripts";
% LOG_DISARMED: 1 logs all the time, armed or not; 2 the same except when
% USB is plugged in; 3 throws the log away if the Cube is never armed, so
% it's no good here (ArduPilot's AP_Logger.cpp). Any value is fine: the
% Logs panel on the Run tab starts and stops the log by changing it.
params(end+1) = entry(1, g, "LOG_DISARMED", NaN, anyValue, false, ...
    "1: the Cube's own log records while disarmed (it always is here). Start and stop it with Logs on the Run tab.");
if level >= 2    % cubegui.lua is needed from level 2
    params(end+1) = entry(1, g, "SCR_ENABLE", 1, @(v) v == 1, false, ...
        "1 runs Lua scripts from APM/scripts on the SD card, including cubegui.lua. Changing it needs a reboot.");
else
    params(end+1) = entry(1, g, "SCR_ENABLE", NaN, anyValue, false, ...
        "1 runs Lua scripts from APM/scripts on the SD card. Changing it needs a reboot.");
end
params(end+1) = entry(1, g, "STEST_CHAN", NaN, anyValue, false, ...
    "servo_slew.lua (from the guide): the output it sweeps, or 0 for off.");
params(end+1) = entry(1, g, "STEST_FREQ", NaN, anyValue, false, ...
    "servo_slew.lua: sweeps per second.");
params(end+1) = entry(1, g, "STEST_PCT", NaN, anyValue, false, ...
    "servo_slew.lua: how much of its range to sweep, in percent.");

% ---- Level 2: RC, arming ---------------------------------------------------------
g = "Safety and arming";
params(end+1) = entry(2, g, "BRD_SAFETY_MASK", NaN, anyValue, false, ...
    "Outputs that work even with the safety switch on. Add up 2^(n-1) for each output n: output 5 is 16.");
params(end+1) = entry(2, g, "ARMING_CHECK", NaN, anyValue, false, ...
    "Which checks the Cube runs before arming. CubeGUI never arms the Cube.");

% ---- Level 2: cubegui.lua, the script that lets RC and the closed loop drive ----------
% "Not on this Cube" for these means the script isn't running: see lua/README.md.
g = "cubegui.lua: modes and RC";
params(end+1) = entry(2, g, "CGUI_ENABLE", NaN, anyValue, false, ...
    "1 lets cubegui.lua drive servos in RC and closed-loop modes. 0 leaves everything to CubeGUI.");
params(end+1) = entry(2, g, "CGUI_MODE_FUNC", NaN, anyValue, false, ...
    ['The mode switch is the channel whose RCn_OPTION is this (normally 300): low RC, high CubeGUI. ' ...
     'Set RCn_OPTION on your switch''s channel: type e.g. RC7_OPTION in Add parameter, below the table.']);
params(end+1) = entry(2, g, "CGUI_SAS_FUNC", NaN, anyValue, false, ...
    'The SAS switch (pitch damping in RC mode) is the channel whose RCn_OPTION is this (normally 301): low off, high on.');
params(end+1) = entry(2, g, "CGUI_ELEV_OUT", NaN, anyValue, false, ...
    "The elevator's output, for the closed loop and SAS: 5 for MAIN OUT 5.");
for n = 1:4
    params(end+1) = entry(2, g, sprintf("CGUI_M%d_RC", n), NaN, anyValue, false, ...
        sprintf("In RC mode, the transmitter channel that drives CGUI_M%d_OUT. 0 for unused.", n)); %#ok<AGROW>
    params(end+1) = entry(2, g, sprintf("CGUI_M%d_OUT", n), NaN, anyValue, false, ...
        sprintf("In RC mode, the output that channel CGUI_M%d_RC drives.", n)); %#ok<AGROW>
end

% ---- Level 3: the closed loop's gains ------------------------------------------------------
g = "cubegui.lua: closed loop";
params(end+1) = entry(3, g, "CGUI_KP", NaN, @(v) v >= 0, false, ...
    "P gain: microseconds of elevator per degree of pitch error.");
params(end+1) = entry(3, g, "CGUI_KI", NaN, @(v) v >= 0, false, ...
    "I gain: microseconds per degree-second of error. Removes a steady error.");
params(end+1) = entry(3, g, "CGUI_KD", NaN, @(v) v >= 0, false, ...
    "D gain: microseconds per degree/second of pitch rate. Damps the motion.");
params(end+1) = entry(3, g, "CGUI_IMAX", NaN, @(v) v >= 0, false, ...
    "The most the I term may add, in microseconds.");
params(end+1) = entry(3, g, "CGUI_SAS_KD", NaN, @(v) v >= 0, false, ...
    "SAS damping in RC mode: microseconds of elevator per degree/second of pitch rate.");

% ---- Anything else you asked for, at every level -----------------------------------
for name = reshape(string(extraNames), 1, [])
    if ~ismember(name, [params.name])
        params(end+1) = entry(0, "Your parameters", name, NaN, anyValue, false, ...
            "Added by you."); %#ok<AGROW>
    end
end

params = params([params.level] <= level);
end

function e = entry(level, group, name, wanted, isOk, readOnly, why)
e = struct("level", level, "group", string(group), "name", string(name), "wanted", wanted, ...
    "isOk", isOk, "readOnly", readOnly, "why", string(why));
end
