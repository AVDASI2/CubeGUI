classdef ServoMapping
    %SERVOMAPPING  Turns a slider value (PWM, degrees, percent...) into PWM, and back.
    %
    %   m = ServoMapping(servo)   % servo: one entry of "servos" in the settings
    %   pwm = m.toPwm(10)         % e.g. 10 degrees -> PWM in us (not yet clamped)
    %   x = m.toValue(1620)       % PWM -> slider units, for showing outputs
    %
    %   The "mapping" entry in the settings picks how. If it's missing, the
    %   slider is the PWM itself, in microseconds. The types:
    %
    %     "pwm"          minPwm..maxPwm us: the slider is the PWM sent
    %     "percent"      -100..100 %: 0 is trim, +-100 is maxPwm/minPwm
    %     "table"        a calibration table: "points": [[x1, pwm1], [x2, pwm2], ...]
    %                    with straight lines between the points
    %     "linear"       pwm = m*x + c          ("m", "c")
    %     "exponential"  pwm = a*exp(b*x) + c   ("a", "b", "c")
    %     "custom"       pwm = any formula in x ("expression", e.g. "1500 + 20*x + 0.5*x^2")
    %
    %   Every type except pwm and percent also needs "units" (e.g. "deg") and,
    %   except table, a "range" for the slider: [low, high] in those units.
    %
    %   Whatever the mapping gives, the PWM sent is still clamped to minPwm..maxPwm.
    %
    %   This is a value class (no "< handle"): it never changes once made,
    %   so copies behave like numbers do.

    properties (SetAccess = private)
        Type      % "pwm", "percent", "table", "linear", "exponential" or "custom"
        Units     % e.g. "µs", "%" or "deg"
        Range     % [low high] slider range, in Units
    end

    properties (Access = private)
        Fcn       % function handle: slider value -> PWM
        GridX     % the mapping sampled across the range, for going back from PWM
        GridPwm
    end

    methods
        function obj = ServoMapping(servo)
            if isfield(servo, "mapping") && ~isempty(servo.mapping)
                m = servo.mapping;
            else
                m = struct("type", "pwm");
            end
            if ~isfield(m, "type")
                error("CubeGUI:mapping", "mapping needs a ""type"".")
            end
            obj.Type = string(m.type);

            switch obj.Type
                case "pwm"
                    obj.Units = "µs";
                    obj.Range = [servo.minPwm servo.maxPwm];
                    obj.Fcn = @(x) x;
                case "percent"
                    obj.Units = "%";
                    obj.Range = [-100 100];
                    lo = servo.minPwm; trim = servo.trimPwm; hi = servo.maxPwm;
                    obj.Fcn = @(x) (x >= 0) .* (trim + x / 100 * (hi - trim)) + ...
                                   (x < 0)  .* (trim + x / 100 * (trim - lo));
                case "table"
                    points = ServoMapping.need(m, "points");
                    if ~isnumeric(points) || size(points, 2) ~= 2 || size(points, 1) < 2
                        error("CubeGUI:mapping", ['mapping.points must be a list of at least ' ...
                            'two [value, pwm] pairs, like [[-20, 1100], [0, 1500], [20, 1900]].'])
                    end
                    if any(diff(points(:, 1)) <= 0)
                        error("CubeGUI:mapping", "mapping.points must be in increasing order of value.")
                    end
                    obj.Units = ServoMapping.units(servo);
                    obj.Range = [points(1, 1), points(end, 1)];
                    xs = points(:, 1);
                    ps = points(:, 2);
                    % Straight lines between points; held at the end values outside them.
                    obj.Fcn = @(x) interp1(xs, ps, min(max(x, xs(1)), xs(end)));
                case "linear"
                    k = ServoMapping.need(m, "m");
                    c = ServoMapping.need(m, "c");
                    obj.Units = ServoMapping.units(servo);
                    obj.Range = ServoMapping.range(servo);
                    obj.Fcn = @(x) k * x + c;
                case "exponential"
                    a = ServoMapping.need(m, "a");
                    b = ServoMapping.need(m, "b");
                    c = ServoMapping.need(m, "c");
                    obj.Units = ServoMapping.units(servo);
                    obj.Range = ServoMapping.range(servo);
                    obj.Fcn = @(x) a * exp(b * x) + c;
                case "custom"
                    expr = string(ServoMapping.need(m, "expression"));
                    obj.Units = ServoMapping.units(servo);
                    obj.Range = ServoMapping.range(servo);
                    obj.Fcn = ServoMapping.formula(expr);
                otherwise
                    error("CubeGUI:mapping", ['mapping.type "%s" isn''t one CubeGUI knows. ' ...
                        'Use pwm, percent, table, linear, exponential or custom.'], obj.Type)
            end

            % Sample the mapping across the slider's range. This checks it
            % gives sensible numbers, and lets toValue work backwards.
            obj.GridX = linspace(obj.Range(1), obj.Range(2), 2001);
            try
                obj.GridPwm = obj.Fcn(obj.GridX);
            catch err
                error("CubeGUI:mapping", "The mapping couldn't be worked out: %s", err.message)
            end
            if ~isequal(size(obj.GridPwm), size(obj.GridX)) || ~all(isfinite(obj.GridPwm)) ...
                    || ~isreal(obj.GridPwm)
                error("CubeGUI:mapping", "The mapping gives a non-number somewhere in its range.")
            end
            % It must only go one way (always up or always down), or one PWM
            % could mean two different slider positions.
            steps = diff(obj.GridPwm);
            if ~(all(steps > 0) || all(steps < 0))
                error("CubeGUI:mapping", ['The mapping must always increase or always ' ...
                    'decrease across its range.'])
            end
        end

        function pwm = toPwm(obj, x)
            % Slider value -> PWM, rounded to a whole microsecond. Values
            % beyond the range are held at its ends.
            x = min(max(x, obj.Range(1)), obj.Range(2));
            pwm = round(obj.Fcn(x));
        end

        function x = toValue(obj, pwm)
            % PWM -> slider units. Works on whole arrays at once, for plots.
            % Not limited to the range, so an output beyond it shows up.
            if obj.GridPwm(end) > obj.GridPwm(1)
                x = interp1(obj.GridPwm, obj.GridX, pwm, "linear", "extrap");
            else
                x = interp1(flip(obj.GridPwm), flip(obj.GridX), pwm, "linear", "extrap");
            end
        end
    end

    methods (Static, Access = private)
        function value = need(m, name)
            if ~isfield(m, name)
                error("CubeGUI:mapping", "A ""%s"" mapping needs ""%s"".", m.type, name)
            end
            value = m.(name);
        end

        function u = units(servo)
            if ~isfield(servo, "units") || strlength(string(servo.units)) == 0
                error("CubeGUI:mapping", 'This mapping needs "units", e.g. "deg".')
            end
            u = string(servo.units);
        end

        function r = range(servo)
            if ~isfield(servo, "range") || ~isnumeric(servo.range) || numel(servo.range) ~= 2 ...
                    || servo.range(1) >= servo.range(2)
                error("CubeGUI:mapping", ['This mapping needs "range": [low, high], the ' ...
                    'slider''s ends in its units.'])
            end
            r = reshape(servo.range, 1, 2);
        end

        function f = formula(expr)
            % Turn a formula like "1500 + 20*x" into a function. Only x,
            % numbers, arithmetic and a few maths functions are allowed, so
            % a settings file can't run arbitrary MATLAB.
            allowed = ["x", "exp", "log", "sqrt", "sin", "cos", "tan", "abs", "pi"];
            if ~isempty(regexp(expr, "[^\w\s.+\-*/^()]", "once"))
                error("CubeGUI:mapping", ['mapping.expression may only use x, numbers, ' ...
                    '+ - * / ^ ( ) and maths functions.'])
            end
            % Blank out the numbers (including ones like 1.5e3), then every
            % word left must be x or an allowed function.
            noNumbers = regexprep(expr, "(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?", " ");
            words = string(regexp(noNumbers, "[A-Za-z_]\w*", "match"));
            notAllowed = words(~ismember(words, allowed));
            if ~isempty(notAllowed)
                error("CubeGUI:mapping", ['mapping.expression uses "%s", which isn''t ' ...
                    'allowed. Use x for the slider value.'], notAllowed(1))
            end
            % Make * / ^ work element by element (.* ./ .^), so the formula
            % works on a whole array of slider values at once.
            elementwise = regexprep(expr, "(?<!\.)([*/^])", ".$1");
            f = str2func("@(x) " + elementwise);
        end
    end
end
