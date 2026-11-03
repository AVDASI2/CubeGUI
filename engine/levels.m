function list = levels()
%LEVELS  CubeGUI's capability levels, and what each one unlocks.
%
%   Part of CubeGUI's engine. You don't need to change this: the level to
%   use is "level" in the settings file.
%
%   list = levels()   % one struct per level: number, name, unlocks, released
%
%   Levels add features as the unit goes on, so the window stays simple
%   at the start. Each level includes everything below it. Panels in the
%   settings file can have their own "level" too.
%
%   Levels hide features; they don't lock them. Anyone can change the level
%   in the settings file, or open CubeGUI(Level=3).
%
%   The tunnel settings files (config/fuselage.json and the wings) aren't a
%   level: they're ready-made settings, at level 3, for the wind-tunnel tests.
%
%   "released" is false for a level that's in the code but not released to
%   students yet: tested on ArduPilot's simulator, not yet on the kits, and
%   not supported. The window says "preview" in its title at those levels.
%   Set it to true when a level is released.

list = struct("number", {}, "name", {}, "unlocks", {}, "released", {});
list(end+1) = level(0, "Simulate", true, ...
    "The Simulated source, its plots, and servo sliders that drive the simulation.");
list(end+1) = level(1, "Connect and log", true, ...
    "The real Cube, over the Wi-Fi or a USB cable (connection, safety switch, servos and " + ...
    "the Setup tab, with flashing ArduPlane and resetting to a fresh Cube), logging to CSV, " + ...
    "the Cube's own log, run markers, values from Lua scripts, and calibration.");
list(end+1) = level(2, "RC", false, ...
    "Control from an RC transmitter through lua/cubegui.lua, and a display of who's in charge.");
list(end+1) = level(3, "Closed loop", false, ...
    "A pitch controller on the Cube (lua/cubegui.lua), with its target and gains in CubeGUI.");
end

function L = level(number, name, released, unlocks)
L = struct("number", number, "name", string(name), "unlocks", string(unlocks), ...
    "released", released);
end
