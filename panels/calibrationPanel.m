function panel = calibrationPanel(parent, cube, options)
%CALIBRATIONPANEL  Step a servo through its range and record the surface angle.
%
%   In config/cubegui.json, under "controls":
%       {"panel": "calibrationPanel", "servo": "Elevator", "level": 1}
%       {"panel": "calibrationPanel", "servo": "Elevator", "steps": 9}
%
%   The panel itself is just a button: the calibration opens in a window of
%   its own, with room for the steps, a plot and the result.
%
%   1. Click Start. The servo goes to the first PWM (its SERVOn_MIN).
%   2. Measure the surface's angle, type it in degrees, and click Record.
%      The servo moves to the next PWM. Repeat.
%   3. It goes up to SERVOn_MAX, then back down, so every PWM is measured
%      both ways: the difference shows the mechanism's hysteresis.
%      Back goes to the step before, even after the end, to measure it again.
%   4. At the end, the window shows the settings to paste into the servo's
%      entry in the settings file, so its slider works in degrees.
%
%   "steps" is how many PWM values from MIN to MAX (default 9).

name = string(options.servo);
steps = 9;
if isfield(options, "steps")
    steps = options.steps;
end

% ---- Build the panel (runs once, when the window opens) ------------------
box = uipanel(parent, Title="Calibrate " + name);
grid = uigridlayout(box, [1 2], ColumnWidth={"1x", 130}, Padding=[8 4 8 4]);
uilabel(grid, WordWrap="on", Text="So its slider can work in degrees.", ...
    Tooltip="Measure the surface's angle at each PWM, so its slider can work in degrees.");
uibutton(grid, Text="Open calibration...", ...
    ButtonPushedFcn=@(~, ~) openWindow(cube, name, steps, box));

% ---- Hand back what the window needs -------------------------------------
panel.height = 70;   % no panel.update: it only changes when a button is pressed
end

% ==========================================================================
% The calibration window

function openWindow(cube, name, steps, box)
% Open the calibration window, or bring it to the front if it's open already.
if ~isempty(box.UserData) && isvalid(box.UserData)
    figure(box.UserData);
    return
end
% The same size as CubeGUI's window, or 900 x 600 if that's smaller, so it
% fits a small or scaled screen too.
mainWindow = ancestor(box, "figure");
windowSize = min([900 600], mainWindow.Position(3:4));
fig = uifigure(Name="Calibrate " + name, Position=[mainWindow.Position(1:2) + 20, windowSize]);
box.UserData = fig;
% Close it with CubeGUI's window, so it's never left behind.
closer = addlistener(mainWindow, "ObjectBeingDestroyed", @(~, ~) delete(fig));
fig.DeleteFcn = @(~, ~) delete(closer);

g = uigridlayout(fig, [1 2], ColumnWidth={"1x", "1.2x"});

% ---- Left: what to do, the controls, and the steps ----
left = uigridlayout(g, [5 1], RowHeight={"fit", 30, 32, 32, "1x"}, Padding=[0 0 0 0]);
uilabel(left, WordWrap="on", Text= ...
    "Turn the safety switch off, then click Start. The servo goes to its SERVOn_MIN. " + ...
    "Measure the surface's angle (an inclinometer or protractor), type it in degrees, " + ...
    "and click Record: the servo moves to the next step. It goes up to SERVOn_MAX and " + ...
    "back down, so each PWM is measured both ways. Back goes to the step before, to measure it again.");
where = uilabel(left, Text="Click Start to begin.", FontSize=16, FontWeight="bold");

row = uigridlayout(left, [1 3], ColumnWidth={"1x", 100, 100}, Padding=[0 0 0 0]);
uilabel(row, Text="Angle measured (deg)", HorizontalAlignment="right");
angleBox = uieditfield(row, "numeric", Enable="off");
recordButton = uibutton(row, Text="Record", Enable="off");

row2 = uigridlayout(left, [1 3], ColumnWidth={100, 100, "1x"}, Padding=[0 0 0 0]);
startButton = uibutton(row2, Text="Start");
backButton = uibutton(row2, Text="Back", Enable="off");
uilabel(row2, Text="");

stepTable = uitable(left, ColumnName=["Step", "PWM (µs)", "Moving", "Angle (deg)"], ...
    RowName={}, Data=table(zeros(0, 1), zeros(0, 1), strings(0, 1), strings(0, 1)));

% ---- Right: the plot, and the result ----
right = uigridlayout(g, [5 1], RowHeight={"1x", 22, 70, 30, "fit"}, Padding=[0 0 0 0]);
ax = uiaxes(right);
xlabel(ax, "PWM (µs)")
ylabel(ax, "Angle (deg)")
ax.XGrid = "on";
ax.YGrid = "on";
hold(ax, "on")
upLine = plot(ax, NaN, NaN, "o-", DisplayName="going up");
downLine = plot(ax, NaN, NaN, "x--", DisplayName="going down");
legend(ax, Location="northwest");
summary = uilabel(right, Text="");
result = uitextarea(right, Editable="off", Value="", ...
    Placeholder="The settings to paste appear here when you've finished.");
copyRow = uigridlayout(right, [1 2], ColumnWidth={130, "1x"}, Padding=[0 0 0 0]);
copyButton = uibutton(copyRow, Text="Copy settings", Enable="off");
uilabel(copyRow, Text="");
nextSteps = uilabel(right, WordWrap="on", Text="");

% Everything the buttons need, kept in the window's UserData (see recipe 7
% in docs/recipes.md) so each button's function can read and change it.
fig.UserData = struct("pwm", [], "up", [], "angle", [], "step", 0);
ui = struct("fig", fig, "where", where, "angle", angleBox, "record", recordButton, ...
    "back", backButton, "start", startButton, "table", stepTable, "upLine", upLine, ...
    "downLine", downLine, "summary", summary, "result", result, "next", nextSteps, ...
    "copy", copyButton, "servo", name);
startButton.ButtonPushedFcn = @(~, ~) start(cube, name, steps, ui);
% Only the Record button records. (If typing in the box recorded too,
% typing then clicking Record would record twice and skip a step.)
recordButton.ButtonPushedFcn = @(~, ~) record(cube, name, ui);
backButton.ButtonPushedFcn = @(~, ~) goBack(cube, name, ui);
copyButton.ButtonPushedFcn = @(~, ~) copySettings(ui);
end

function start(cube, name, steps, ui)
% Plan the sweep: MIN up to MAX, then back down to MIN.
s = cube.servo(name);
if ~s.ready
    ui.where.Text = "Can't start: " + s.why;
    ui.where.Tooltip = ui.where.Text;
    return
end
upPwm = round(linspace(s.minPwm, s.maxPwm, steps));
pwm = [upPwm, flip(upPwm(1:end-1))];
up = [true(1, steps), false(1, steps - 1)];
ui.fig.UserData = struct("pwm", pwm, "up", up, "angle", NaN(size(pwm)), "step", 1);
ui.start.Text = "Start again";
showSteps(ui);
goToStep(cube, name, ui);
end

function record(cube, name, ui)
% Keep the angle typed for this step, and move on to the next.
data = ui.fig.UserData;
if data.step < 1 || data.step > numel(data.pwm)
    return
end
data.angle(data.step) = ui.angle.Value;
data.step = data.step + 1;
ui.fig.UserData = data;
showSteps(ui);
if data.step > numel(data.pwm)
    finish(ui);
else
    goToStep(cube, name, ui);
end
end

function goBack(cube, name, ui)
% One step back, to measure it again. After the end, that's the last step.
data = ui.fig.UserData;
data.step = max(1, min(data.step - 1, numel(data.pwm)));
ui.fig.UserData = data;
goToStep(cube, name, ui);
end

function goToStep(cube, name, ui)
% Move to this step, ready to record it (also when coming back from the end).
data = ui.fig.UserData;
k = data.step;
cube.moveServoPwm(name, data.pwm(k));
ui.angle.Enable = "on";
ui.record.Enable = "on";
ui.back.Enable = k > 1;
ui.result.Value = "";
ui.summary.Text = "";
ui.summary.Tooltip = ui.summary.Text;
ui.next.Text = "";
ui.copy.Enable = "off";
ui.copy.Text = "Copy settings";
if ~isnan(data.angle(k))
    ui.angle.Value = data.angle(k);   % what was recorded here before
end
direction = "going down";
if data.up(k)
    direction = "going up";
end
ui.where.Text = sprintf("Step %d of %d: %d µs, %s", k, numel(data.pwm), data.pwm(k), direction);
ui.where.Tooltip = ui.where.Text;
ui.table.Selection = [k 1];
end

function showSteps(ui)
% The table of steps, and the plot of what's been measured so far.
data = ui.fig.UserData;
n = numel(data.pwm);
moving = repmat("up", n, 1);
moving(~data.up) = "down";
angles = compose("%.1f", data.angle');   % one decimal place, blank until measured
angles(isnan(data.angle')) = "";
ui.table.Data = table((1:n)', data.pwm', moving, angles);
set(ui.upLine, XData=data.pwm(data.up), YData=data.angle(data.up));
set(ui.downLine, XData=data.pwm(~data.up), YData=data.angle(~data.up));
end

function finish(ui)
% Work out the table, and show the settings to paste and what to do next.
data = ui.fig.UserData;
ui.where.Text = "Finished.";
ui.where.Tooltip = ui.where.Text;
ui.angle.Enable = "off";
ui.record.Enable = "off";
ui.back.Enable = "on";
try
    t = calibrationTable(data.pwm, data.angle, data.up);
    ui.summary.Text = sprintf("Hysteresis: up to %.1f deg between going up and going down.", t.hysteresis);
    ui.summary.Tooltip = ui.summary.Text;
    ui.result.Value = splitlines(string(t.settings));
    ui.copy.Enable = "on";
    ui.next.Text = [ ...
        "Next: click Copy settings. In your settings file, find the " + ui.servo + "'s { } " + ...
        "entry under ""servos"" and paste them in after its ""output"" (with a comma " + ...
        "before). Save, and start CubeGUI again: its slider then works in degrees. " + ...
        "Check one or two angles by measuring. Hysteresis means the angle depends on " + ...
        "which way the surface last moved, so approach each test angle from the same side. " + ...
        "Calibrate again after any change to the linkage."];
catch err
    ui.summary.Text = err.message;
    ui.summary.Tooltip = ui.summary.Text;
end
end

function copySettings(ui)
% Put the settings text on the clipboard, ready to paste.
clipboard("copy", strjoin(string(ui.result.Value), newline));
ui.copy.Text = "Copied";
end
