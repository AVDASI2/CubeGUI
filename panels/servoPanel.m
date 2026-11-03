function panel = servoPanel(parent, cube, options)
%SERVOPANEL  A slider, a number box and two readouts for one servo.
%
%   In config/cubegui.json, under "controls":
%       {"panel": "servoPanel", "servo": "Elevator"}
%
%   To make a panel of your own, copy this file, give the copy a new name
%   (the file name and the name on the first line must match), and add it
%   to "controls" in the settings file. docs/recipes.md has examples.

name = string(options.servo);   % which servo, by its name in the settings
s = cube.servo(name);           % its details: units, range, output number...

% ---- Build the panel (runs once, when the window opens) ------------------
box = uipanel(parent, Title=sprintf("%s (output %d)", s.name, s.output));
grid = uigridlayout(box, [4 2], RowHeight={42, 26, 18, 18}, RowSpacing=4, ...
    Padding=[8 4 8 4]);

start = mean(s.range);          % the middle, until the Cube's own trim arrives
slider = uislider(grid, Limits=s.range, Value=start);
slider.Layout.Column = [1 2];     % the slider spans both columns

uilabel(grid, Text="Value (" + s.units + ")");
numberBox = uieditfield(grid, "numeric", Limits=s.range, Value=start, ...
    ValueDisplayFormat=numberFormat(s.units));

sentLabel = uilabel(grid, Text="");
sentLabel.Layout.Column = [1 2];
outputLabel = uilabel(grid, Text="Output: no data");
outputLabel.Layout.Column = [1 2];

% What happens when someone drags the slider, lets go, or types a number.
slider.ValueChangingFcn = @(~, event) moveTo(cube, name, event.Value, numberBox);
slider.ValueChangedFcn  = @(~, event) moveTo(cube, name, event.Value, numberBox);
numberBox.ValueChangedFcn = @(~, event) moveTo(cube, name, event.Value, slider);

% ---- Hand back what the window needs -------------------------------------
panel.height = 150;   % in pixels
panel.update = @() showLatest(cube, name, box, slider, numberBox, sentLabel, outputLabel);
end

% ==========================================================================

function moveTo(cube, name, value, otherControl)
% Keep the slider and the box showing the same value, then move the servo.
% cube.moveServo does the rest: units to PWM, the safety limits, and not
% flooding the Wi-Fi while you drag.
otherControl.Value = value;
cube.moveServo(name, value);
end

function showLatest(cube, name, box, slider, numberBox, sentLabel, outputLabel)
% Runs 10 times a second, while the window is open.
s = cube.servo(name);

% The slider's ends can change when the Cube's limits arrive (a PWM slider
% runs from SERVOn_MIN to SERVOn_MAX). Then start it at the trim position.
if ~isequal(slider.Limits, s.range)
    slider.Limits = s.range;
    numberBox.Limits = s.range;
    if ~isnan(s.trim) && isnan(cube.servoTarget(name))
        slider.Value = min(max(s.trim, s.range(1)), s.range(2));
        numberBox.Value = slider.Value;
    end
end

% The controls only work once CubeGUI has the servo's limits from the Cube.
if logical(slider.Enable) ~= s.ready
    slider.Enable = s.ready;
    numberBox.Enable = s.ready;
end
if s.ready
    title = string(sprintf("%s (output %d, %d to %d µs)", s.name, s.output, s.minPwm, s.maxPwm));
else
    title = string(sprintf("%s (output %d)", s.name, s.output));
end
if box.Title ~= title    % only change it when it's different: it's quicker
    box.Title = title;
end

asked = cube.servoTarget(name);    % the last position asked for, in its units
if ~isnan(asked) && asked ~= numberBox.Value
    % Something else moved this servo (Zero all, say): catch up with it.
    slider.Value = asked;
    numberBox.Value = asked;
end

if s.ready
    sentLabel.Text = "Sent: " + describe(cube.servoSent(name), s.units);
else
    sentLabel.Text = upper(extractBefore(s.why, 2)) + extractAfter(s.why, 1);  % e.g. "Connect to use..."
end
outputLabel.Text = "Output: " + describe(cube.latest(name), s.units);
end

function text = describe(value, units)
% e.g. "1620 µs", "+25 %" or "-4.5 deg", or "no data".
if isnan(value)
    text = "no data";
elseif units == "µs"
    text = string(sprintf("%.0f %s", value, units));
elseif units == "%"
    text = string(sprintf("%+.0f %s", value, units));
else
    text = string(sprintf("%+.1f %s", value, units));
end
end

function format = numberFormat(units)
% How the number box shows its value. %% is how to write a % sign here.
if units == "µs"
    format = "%.0f µs";
elseif units == "%"
    format = "%.0f %%";
else
    format = "%.1f " + units;
end
end
