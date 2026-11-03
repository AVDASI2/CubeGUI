function panel = modePanel(parent, cube, options)
%MODEPANEL  Who's in charge of the servos, and (from level 3) the closed loop.
%
%   In config/cubegui.json, under "controls":
%       {"panel": "modePanel", "level": 2}
%
%   Needs lua/cubegui.lua on the Cube (see lua/README.md). It shows whether
%   CubeGUI, the transmitter or the closed loop is driving the servos. From
%   level 3 it also has buttons to hand the elevator to the closed loop and
%   back, a pitch target, and stability augmentation (SAS) on or off.
%   Optional: "maxTarget" (degrees, default 20), the pitch target slider's ends.

maxTarget = 20;
if isfield(options, "maxTarget")
    maxTarget = options.maxTarget;
end
closedLoop = cube.Level >= 3;   % the closed-loop controls come at level 3

% ---- Build the panel (runs once, when the window opens) ------------------
box = uipanel(parent, Title="Who's in charge");
if closedLoop
    grid = uigridlayout(box, [5 2], RowHeight={30, 18, 30, 42, 24}, RowSpacing=4, ...
        Padding=[8 4 8 4]);
else
    grid = uigridlayout(box, [2 2], RowHeight={30, 18}, RowSpacing=4, Padding=[8 4 8 4]);
end

% A lamp and a big label: who's driving now.
top = uigridlayout(grid, [1 2], ColumnWidth={24, "1x"}, Padding=[0 0 0 0]);
top.Layout.Column = [1 2];
lamp = uilamp(top, Color=[0.6 0.6 0.6]);
who = uilabel(top, Text="Not connected", FontSize=16, FontWeight="bold");

details = uilabel(grid, Text="");   % the script, RC and SAS, in small type
details.Layout.Column = [1 2];

controls = struct();
if closedLoop
    controls.gui = uibutton(grid, Text="CubeGUI drives", ...
        ButtonPushedFcn=@(~, ~) cube.requestMode("gui"));
    controls.loop = uibutton(grid, Text="Closed loop", ...
        ButtonPushedFcn=@(~, ~) cube.requestMode("closed loop"));

    controls.slider = uislider(grid, Limits=[-maxTarget maxTarget], Value=0);
    controls.slider.Layout.Column = [1 2];
    controls.slider.ValueChangingFcn = @(~, event) cube.setPitchTarget(event.Value);
    controls.slider.ValueChangedFcn = @(~, event) cube.setPitchTarget(event.Value);

    controls.target = uilabel(grid, Text="Pitch target: 0.0 deg");
    controls.sas = uicheckbox(grid, Text="SAS in RC mode", ...
        ValueChangedFcn=@(src, ~) cube.setSas(src.Value));
end

% ---- Hand back what the window needs -------------------------------------
if closedLoop
    panel.height = 190;
else
    panel.height = 80;
end
panel.update = @() showMode(cube, lamp, who, details, controls);
end

% ==========================================================================

function showMode(cube, lamp, who, details, controls)
% Runs 10 times a second.
m = cube.mode();
if ~cube.isConnected()
    setIfDifferent(who, "Text", "Not connected");
    lamp.Color = [0.6 0.6 0.6];
    setIfDifferent(details, "Text", "");
    return
end

% Grey: no script. Green: CubeGUI. Blue: transmitter. Amber: closed loop.
colours = [0 0.75 0; 0 0.4 1; 1 0.7 0];
if ~m.script
    lamp.Color = [0.6 0.6 0.6];
    setIfDifferent(who, "Text", "CubeGUI (no script heard)");
    setIfDifferent(details, "Text", "cubegui.lua isn't reporting: see lua/README.md.");
else
    lamp.Color = colours(m.code + 1, :);
    setIfDifferent(who, "Text", m.name);
    if m.rc
        rcText = "RC: OK";
    else
        rcText = "RC: none";
    end
    sasText = "SAS: off";
    if m.sas
        sasText = "SAS: on";
    end
    setIfDifferent(details, "Text", sprintf("Script running.  %s.  %s.", rcText, sasText));
end

if isfield(controls, "target")
    target = m.target;
    if isnan(target)
        target = controls.slider.Value;
    end
    setIfDifferent(controls.target, "Text", sprintf("Pitch target: %+.1f deg", target));
end
end

function setIfDifferent(component, property, value)
% Change a property only if it's different: quicker, and no flicker.
if string(component.(property)) ~= string(value)
    component.(property) = value;
end
end
