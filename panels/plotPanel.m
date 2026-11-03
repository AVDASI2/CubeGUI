function panel = plotPanel(parent, cube, options)
%PLOTPANEL  A live plot of one signal over the last 30 seconds or so.
%
%   In config/cubegui.json, under "plots":
%       {"panel": "plotPanel", "signal": "pitch"}
%       {"panel": "plotPanel", "signal": "pitch rate"}
%       {"panel": "plotPanel", "signal": "Elevator"}    a servo, by its name
%       {"panel": "plotPanel", "signal": "DEMO"}        a value from a Lua script
%
%   Optional entries:
%       "label"    what to call it; the signal's name if it's missing
%       "range"    the ends of the y-axis, like [-30, 30]; it picks its own if missing
%       "height"   "2x" makes it twice as tall as a normal ("1x") plot
%       "title"    true to show the latest value above the plot, false not to
%       "compare"  a second signal, drawn dashed on the same plot, like
%                  "CG_TGT" (the closed loop's pitch target) on the pitch plot
%
%   For a servo, the solid line is what the Cube reports the servo is
%   doing, and the dashed line is what CubeGUI last sent.

signal = string(options.signal);
units = cube.units(signal);
isServo = any(lower(cube.servoNames()) == lower(signal));
label = upper(extractBefore(signal, 2)) + extractAfter(signal, 1);   % "pitch" -> "Pitch"
if isfield(options, "label")
    label = string(options.label);
end
showTitle = ~isServo;   % a servo's panel already shows its latest value
if isfield(options, "title")
    showTitle = options.title;
end

% ---- Build the plot (runs once, when the window opens) -------------------
ax = uiaxes(parent);
dataLine = plot(ax, NaN, NaN, LineWidth=1.5);
hold(ax, "on")
sentLine = plot(ax, NaN, NaN, "--", LineWidth=1);
ax.XLim = [-cube.PlotSeconds 0];
ax.XGrid = "on";
ax.YGrid = "on";
if units == ""
    ylabel(ax, label)
else
    ylabel(ax, label + " (" + units + ")")
end
if isfield(options, "isLast") && options.isLast   % the window says which plot is at the bottom
    xlabel(ax, "Time (s, 0 = now)")
end

if isfield(options, "range")
    ax.YLim = options.range;
elseif isServo
    range = cube.servo(signal).range;
    ax.YLim = range + [-0.1 0.1] * diff(range);   % its slider's range, plus a bit
    showServoTicks(ax, cube.servo(signal))
elseif lower(signal) == "pitch"
    ax.YLim = [-20 20];
end   % otherwise MATLAB picks the range as the data comes in

% These plots don't need zooming or dragging. Switching them off saves
% the toolbar's space, and a second or two when the plot first draws.
ax.Toolbar.Visible = "off";
disableDefaultInteractivity(ax)

% ---- Hand back what the window needs -------------------------------------
panel.height = "1x";
if isfield(options, "height")
    panel.height = options.height;
end
compare = "";
if isfield(options, "compare")
    compare = string(options.compare);
end
followRange = isServo && ~isfield(options, "range");   % keep up if the Cube's limits change
panel.update = @() showLatest(cube, signal, label, units, isServo, showTitle, compare, ...
    followRange, ax, dataLine, sentLine);
end

% ==========================================================================

function showLatest(cube, signal, label, units, isServo, showTitle, compare, followRange, ...
    ax, dataLine, sentLine)
% Runs 10 times a second, while the window is open.
if followRange
    % A PWM slider's ends are the Cube's SERVOn_MIN and MAX, which arrive
    % after connecting, so the y-axis follows them.
    info = cube.servo(signal);
    wanted = info.range + [-0.1 0.1] * diff(info.range);
    if ~isequal(ax.YLim, wanted)
        ax.YLim = wanted;
    end
    showServoTicks(ax, info)   % TRIM can change on its own
end
[t, y] = cube.history(signal);    % t = 0 is now, older samples negative
if isempty(t)
    set(dataLine, XData=NaN, YData=NaN);
else
    set(dataLine, XData=t, YData=y);
end

if showTitle
    value = cube.latest(signal);
    if isnan(value)
        text = label;
    else
        text = string(sprintf("%s  %+.1f %s", label, value, units));
    end
    ax.Title.String = text;   % much quicker than calling title()
end

if isServo
    sentLine.XData = [-cube.PlotSeconds 0];
    sentLine.YData = cube.servoSent(signal) * [1 1];
elseif compare ~= ""
    [tc, yc] = cube.history(compare);   % the second signal, dashed
    if isempty(tc)
        set(sentLine, XData=NaN, YData=NaN);
    else
        set(sentLine, XData=tc, YData=yc);
    end
end
end

function showServoTicks(ax, info)
% A servo plot's y-axis marks just the servo's MIN, TRIM and MAX: the values
% that matter, and few enough not to overlap when the plot is short (a
% small window, or many plots). Until the Cube has sent TRIM, MATLAB picks.
ticks = [info.range(1), info.trim, info.range(2)];
if all(isfinite(ticks)) && all(diff(ticks) > 0)
    if ~isequal(ax.YTick, ticks)
        ax.YTick = ticks;
    end
elseif ax.YTickMode ~= "auto"
    ax.YTickMode = "auto";
end
end
