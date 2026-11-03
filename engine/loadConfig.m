function config = loadConfig(file)
%LOADCONFIG  Read CubeGUI's settings from a JSON file and check them.
%
%   config = loadConfig("config/cubegui.json")
%
%   Returns a struct with the same layout as the file. If anything is
%   missing or out of range, it stops with an error naming the entry, so a
%   typo in the file can't quietly send a servo somewhere it shouldn't go.

arguments
    file (1,1) string
end

if ~isfile(file)
    error("CubeGUI:config", "Can't find the settings file %s.", file)
end
try
    config = jsondecode(fileread(file));
catch err
    error("CubeGUI:config", "%s isn't valid JSON (check for a missing comma or quote): %s", ...
        file, err.message)
end

% Shorthand for "stop with a message naming this entry".
bad = @(entry, problem) error("CubeGUI:config", "In %s, %s %s.", file, entry, problem);

% ---- connection -------------------------------------------------------------
requireFields(config, ["connection", "rates", "servos"], "the file", bad)
c = config.connection;
requireFields(c, ["localPort", "cubeAddress", "cubePort"], "connection", bad)
checkPort(c.localPort, "connection.localPort", bad)
checkPort(c.cubePort, "connection.cubePort", bad)
if ~(ischar(c.cubeAddress) || isstring(c.cubeAddress)) || strlength(c.cubeAddress) == 0
    bad("connection.cubeAddress", "must be an address in quotes, like ""192.168.4.1""")
end
config.connection.cubeAddress = string(c.cubeAddress);

% ---- logging (optional: older settings files may not have it) ---------------
if ~isfield(config, "logging")
    config.logging = struct("enabled", true, "folder", "logs");
end
g = config.logging;
requireFields(g, ["enabled", "folder"], "logging", bad)
if ~(islogical(g.enabled) && isscalar(g.enabled))
    bad("logging.enabled", "must be true or false (no quotes)")
end
if ~(ischar(g.folder) || isstring(g.folder)) || strlength(g.folder) == 0
    bad("logging.folder", "must be a folder name in quotes, like ""logs""")
end
config.logging.folder = string(g.folder);
% extraSignals (optional): values from Lua scripts to log, by name.
if ~isfield(g, "extraSignals") || isempty(g.extraSignals)
    config.logging.extraSignals = strings(1, 0);
end
config.logging.extraSignals = reshape(string(config.logging.extraSignals), 1, []);
for name = config.logging.extraSignals
    if strlength(name) == 0 || strlength(name) > 10
        bad("logging.extraSignals", """" + name + """ isn't a Lua value's name (1 to 10 characters)")
    end
end

% ---- setup (optional): extra parameters for the Setup tab -------------------
if ~isfield(config, "setup")
    config.setup = struct("extraParams", strings(1, 0));
end
if ~isfield(config.setup, "extraParams") || isempty(config.setup.extraParams)
    config.setup.extraParams = strings(1, 0);
end
extra = reshape(string(config.setup.extraParams), 1, []);
for name = extra
    if isempty(regexp(name, "^[A-Z][A-Z0-9_]{0,15}$", "once"))
        bad("setup.extraParams", """" + name + """ isn't a parameter name (up to 16 " + ...
            "capital letters, digits and underscores)")
    end
end
config.setup.extraParams = extra;

% ---- rates ------------------------------------------------------------------
r = config.rates;
requireFields(r, ["telemetryHz", "plotSeconds"], "rates", bad)
checkNumber(r.telemetryHz, "rates.telemetryHz", 1, 50, bad)
checkNumber(r.plotSeconds, "rates.plotSeconds", 5, 300, bad)

% ---- servos -----------------------------------------------------------------
s = config.servos;
if ~(isstruct(s) || iscell(s)) || isempty(s)
    bad("servos", "must be a list of at least one servo, each in { }")
end
% jsondecode gives a cell array instead of a struct array if the servos
% don't all have the same entries (one has a "mapping", another doesn't).
% Give every servo every entry, empty where it's missing.
if iscell(s)
    s = sameFields(s);
    config.servos = s;
end
optional = ["units", "range", "mapping"];
for f = optional
    if ~isfield(s, f)
        [s.(f)] = deal([]);
    end
end
config.servos = s;
outputs = zeros(1, numel(s));
for k = 1:numel(s)
    where = sprintf("servos(%d)", k);
    requireFields(s(k), ["name", "output"], where, bad)
    checkNumber(s(k).output, where + ".output", 1, 16, bad)
    if s(k).output ~= round(s(k).output)
        bad(where + ".output", "must be a whole number")
    end
    % The PWM limits used to live here. Now they're the Cube's own
    % SERVOn_MIN, _TRIM and _MAX, so that CubeGUI, RC and Lua scripts all
    % share one set. Say so, rather than quietly ignoring old entries.
    for f = ["minPwm", "trimPwm", "maxPwm"]
        if isfield(s(k), f) && ~isempty(s(k).(f))
            bad(where + "." + f, sprintf(['is no longer used: CubeGUI takes the limits from ' ...
                'the Cube (SERVO%d_MIN, _TRIM and _MAX). Delete minPwm, trimPwm and maxPwm ' ...
                'from the settings file, and change the limits in the Setup tab'], s(k).output))
        end
    end
    outputs(k) = s(k).output;
    config.servos(k).name = string(s(k).name);
    % Check the mapping now, with ArduPilot's default limits, so a mistake
    % in it is found at start-up. The window builds it again with the
    % Cube's own limits once they arrive, from mappingSettings.
    config.servos(k).mappingSettings = s(k).mapping;
    try
        config.servos(k).mapping = ServoMapping(withLimits(s(k), 1100, 1500, 1900));
    catch err
        bad(where + ".mapping", "has a problem: " + err.message)
    end
end
if numel(unique(outputs)) < numel(outputs)
    bad("servos", "has two servos on the same output")
end

% ---- level (optional): which capability level to open at --------------------
% Without it, everything is shown, as before levels existed.
if ~isfield(config, "level")
    config.level = max([levels().number]);
end
checkNumber(config.level, "level", 0, max([levels().number]), bad)
if config.level ~= round(config.level)
    bad("level", "must be a whole number")
end

% ---- plots and controls (optional): the panels on the Run tab -----------------
% Without them, the window has a pitch plot and one plot per servo, and one
% slider per servo plus Zero all.
if ~isfield(config, "plots")
    config.plots = {struct("panel", "plotPanel", "signal", "pitch", "height", "2x")};
    for s = reshape(config.servos, 1, [])
        config.plots{end+1} = struct("panel", "plotPanel", "signal", s.name);
    end
end
if ~isfield(config, "controls")
    config.controls = {};
    for s = reshape(config.servos, 1, [])
        config.controls{end+1} = struct("panel", "servoPanel", "servo", s.name);
    end
    config.controls{end+1} = struct("panel", "zeroAllButton");
end
config.plots = panelList(config.plots, "plots", bad);
config.controls = panelList(config.controls, "controls", bad);

% demo mode (a level drop-down in the window) is switched on by
% CubeGUI(Demo=true), not by the settings file.
config.demo = false;
end

function list = panelList(entries, where, bad)
% Turn the panels listed in the settings file into a struct array, one per
% panel: panel (its file's name), level, and options (everything in its
% { } block, handed to the panel as it is).
if isstruct(entries)
    entries = num2cell(entries);
end
if ~iscell(entries)
    bad(where, "must be a list of panels, each in { }")
end
list = struct("panel", {}, "level", {}, "options", {});
for k = 1:numel(entries)
    e = entries{k};
    entry = sprintf("%s(%d)", where, k);
    if ~isstruct(e) || ~isfield(e, "panel")
        bad(entry, "needs ""panel"": the name of a file in the panels folder, like ""servoPanel""")
    end
    name = string(e.panel);
    if ~isvarname(name)
        bad(entry + ".panel", """" + name + """ isn't a file name (letters, digits and " + ...
            "underscores, starting with a letter, and no .m)")
    end
    level = 0;
    if isfield(e, "level")
        checkNumber(e.level, entry + ".level", 0, max([levels().number]), bad)
        level = e.level;
    end
    list(end+1) = struct("panel", name, "level", level, "options", e); %#ok<AGROW>
end
end

% ---- Helpers ------------------------------------------------------------------

function servo = withLimits(servo, minPwm, trimPwm, maxPwm)
% A copy of one servo's settings with PWM limits added, ready for ServoMapping.
servo.minPwm = minPwm;
servo.trimPwm = trimPwm;
servo.maxPwm = maxPwm;
end

function requireFields(s, names, where, bad)
for name = names
    if ~isstruct(s) || ~isfield(s, name)
        bad(where, "is missing """ + name + """")
    end
end
end

function checkNumber(value, entry, low, high, bad)
if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value)
    bad(entry, "must be a single number")
end
if value < low || value > high
    bad(entry, sprintf("is %g, but must be between %g and %g", value, low, high))
end
end

function checkPort(value, entry, bad)
checkNumber(value, entry, 1, 65535, bad)
if value ~= round(value)
    bad(entry, "must be a whole number")
end
end

function s = sameFields(c)
% Turn a cell array of structs with different fields into one struct array.
names = {};
for k = 1:numel(c)
    if ~isstruct(c{k})
        error("CubeGUI:config", "Each entry in servos must be a { } block.")
    end
    names = union(names, fieldnames(c{k}), "stable");
end
s = repmat(cell2struct(cell(numel(names), 1), names, 1), numel(c), 1);
for k = 1:numel(c)
    for f = fieldnames(c{k})'
        s(k).(f{1}) = c{k}.(f{1});
    end
end
end
