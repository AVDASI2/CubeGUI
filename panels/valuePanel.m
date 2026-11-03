function panel = valuePanel(parent, cube, options)
%VALUEPANEL  The latest value of a signal, in big numbers.
%
%   In config/cubegui.json, under "controls":
%       {"panel": "valuePanel", "signal": "pitch rate"}
%       {"panel": "valuePanel", "signal": "DEMO", "label": "Flap sensor (V)"}
%
%   "signal" can be "pitch", "pitch rate", a servo's name, or the name of a
%   value a Lua script sends. "label" is optional.

signal = string(options.signal);
units = cube.units(signal);
label = upper(extractBefore(signal, 2)) + extractAfter(signal, 1);   % "pitch" -> "Pitch"
if isfield(options, "label")
    label = string(options.label);
end

% ---- Build the panel (runs once, when the window opens) ------------------
box = uipanel(parent, Title=label);
grid = uigridlayout(box, [1 1], Padding=[4 0 4 0]);
number = uilabel(grid, Text="-", FontSize=26, FontWeight="bold", ...
    HorizontalAlignment="center");

% ---- Hand back what the window needs -------------------------------------
panel.height = 80;   % in pixels
panel.update = @() showLatest(cube, signal, units, number);
end

% ==========================================================================

function showLatest(cube, signal, units, number)
% Runs 10 times a second, while the window is open.
value = cube.latest(signal);
if isnan(value)
    text = "-";
else
    text = string(sprintf("%.2f %s", value, units));
end
if number.Text ~= text   % only change it when it's different: it's quicker
    number.Text = text;
end
end
