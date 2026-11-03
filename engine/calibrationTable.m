function result = calibrationTable(pwm, angle, goingUp)
%CALIBRATIONTABLE  Turn measured angles into a calibration table for a servo.
%
%   Part of CubeGUI's engine. calibrationPanel uses it; you don't need to
%   change it.
%
%   result = calibrationTable(pwm, angle, goingUp)
%
%   pwm, angle and goingUp are one entry per measurement: the PWM sent (us),
%   the surface angle measured (degrees), and true if the servo got there
%   moving up (from a lower PWM), false if moving down. Measure each PWM
%   once going up and once going down, and the difference between the two
%   shows the mechanism's hysteresis (its dead band).
%
%   result has:
%     points       [angle, pwm] rows, in increasing order of angle: the
%                  "points" of a "table" mapping in the settings file. Where
%                  a PWM was measured both ways, the angle is the average.
%     hysteresis   the largest difference between going up and going down
%                  at the same PWM, in degrees (NaN if none measured both ways)
%     settings     the text to paste into the servo's entry in the settings file

pwm = round(pwm(:));
angle = angle(:);
goingUp = logical(goingUp(:));
keep = isfinite(pwm) & isfinite(angle);
pwm = pwm(keep);
angle = angle(keep);
goingUp = goingUp(keep);
values = unique(pwm);
if numel(values) < 2
    error("CubeGUI:calibration", "Measure at least two different PWM values.")
end

% For each PWM: the average angle, and the up/down difference if measured both ways.
average = zeros(numel(values), 1);
gaps = NaN(numel(values), 1);
for k = 1:numel(values)
    here = pwm == values(k);
    average(k) = mean(angle(here));
    up = angle(here & goingUp);
    down = angle(here & ~goingUp);
    if ~isempty(up) && ~isempty(down)
        gaps(k) = abs(mean(up) - mean(down));
    end
end
result.hysteresis = max(gaps);    % max ignores NaN; NaN only if every gap is NaN

% The angle must keep going one way as PWM rises, or one angle would mean
% two PWM values. (Usually up; down if the mechanism is reversed.)
steps = diff(average);
if ~(all(steps > 0) || all(steps < 0))
    error("CubeGUI:calibration", ['The angles don''t keep increasing (or keep decreasing) ' ...
        'as the PWM rises. Check the measurements, or measure again with bigger steps.'])
end

[~, order] = sort(average);
result.points = [average(order), values(order)];

% The settings, as they'd appear in the servo's { } block.
pairs = compose("[%.1f, %d]", result.points(:, 1), result.points(:, 2));
result.settings = sprintf('"units": "deg",\n"mapping": {"type": "table", "points": [%s]}', ...
    strjoin(pairs, ", "));
end
