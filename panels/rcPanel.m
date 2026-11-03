function panel = rcPanel(parent, cube, options)
%RCPANEL  What the Cube receives from the RC transmitter, channel by channel.
%
%   In config/cubegui.json, under "controls":
%       {"panel": "rcPanel", "level": 2}
%       {"panel": "rcPanel", "channels": 6}
%
%   Each bar is one channel's pulse width, from 1000 to 2000 us. Move a
%   stick or a switch and watch which bar moves: that's its channel number,
%   for the CGUI_ parameters in the Setup tab. "channels" is how many to
%   show (default 8).

count = 8;
if isfield(options, "channels")
    count = options.channels;
end

% ---- Build the panel (runs once, when the window opens) ------------------
box = uipanel(parent, Title="RC transmitter");
grid = uigridlayout(box, [1 1], Padding=[4 4 4 4]);
ax = uiaxes(grid);
bars = barh(ax, 1:count, 1000 * ones(1, count), BaseValue=1000);   % a horizontal bar chart
ax.XLim = [1000 2000];
ax.YLim = [0.5 count + 0.5];
ax.YDir = "reverse";               % channel 1 at the top
ax.YTick = 1:count;
ax.YTickLabel = "Ch " + (1:count);
ax.XGrid = "on";
xlabel(ax, "Pulse width (us)")
% No zooming or dragging needed here (see plotPanel).
ax.Toolbar.Visible = "off";
disableDefaultInteractivity(ax)

% ---- Hand back what the window needs -------------------------------------
panel.height = 60 + 16 * count;
panel.update = @() showChannels(cube, bars, ax, count);
end

% ==========================================================================

function showChannels(cube, bars, ax, count)
% Runs 10 times a second. Each channel is a signal: "rc1", "rc2" and so on.
values = 1000 * ones(1, count);
anySignal = false;
for ch = 1:count
    pwm = cube.latest("rc" + ch);
    if ~(isnan(pwm) || pwm == 0 || pwm == 65535)    % 0 or 65535: nothing on this channel
        values(ch) = min(max(pwm, 1000), 2000);
        anySignal = true;
    end
end
if ~isequal(bars.YData, values)
    bars.YData = values;
end
if anySignal
    title = "";
else
    title = "No transmitter signal";
end
if string(ax.Title.String) ~= title
    ax.Title.String = title;
end
end
