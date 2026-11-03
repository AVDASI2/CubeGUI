classdef (Abstract) DataSource < handle
    %DATASOURCE  What every data source (the Cube, or the simulation) can do.
    %
    %   The window only ever talks to a DataSource, so it doesn't need to know
    %   which kind it has. This is like an abstract base class in Python
    %   (abc.ABC): SimulatedSource and CubeSource fill in the abstract methods.
    %
    %   Servo commands go through setServo here, which clamps every PWM to
    %   that output's limits before handing it on. The sources' own sending
    %   methods are protected, so nothing outside can get round the clamp.
    %
    %   The limits are the Cube's own SERVOn_MIN and SERVOn_MAX, which the
    %   window passes on once they've arrived. The Cube itself doesn't hold
    %   DO_SET_SERVO to them (checked in ArduPilot's AP_ServoRelayEvents.cpp
    %   and SRV_Channel.cpp), so this clamp is the only one there is.

    properties (SetAccess = protected)
        Telemetry               % where incoming data is stored
        IsConnected = false
        Commanded = NaN(1, 16)  % the last PWM sent to each output (us)
    end

    properties (SetAccess = private)
        % [min max] PWM for each output. NaN means "no limits yet", and
        % CubeGUI won't send anything to an output without limits.
        ServoLimits = NaN(16, 2)
    end

    properties (Constant)
        % Limits outside this range are refused, not clamped: a typo in a
        % Cube parameter mustn't send a servo to an extreme.
        HardMinPwm = 1000
        HardMaxPwm = 2000
    end

    methods (Abstract)
        connect(obj)
        disconnect(obj)
        text = describe(obj)    % a short name for the status bar
        % Ask for these parameters; values arrive in Telemetry.Params.
        requestParams(obj, names)
        % Write one parameter; the Cube's confirmation arrives in Telemetry.Params.
        setParam(obj, name, value)
        % Turn the safety switch on (true: servos held) or off (false: servos
        % live); the Cube's report of its state arrives in Telemetry.SafetyOn.
        setSafety(obj, on)
        % Tell cubegui.lua (the Cube's script) what CubeGUI wants: mode 0
        % (CubeGUI drives) or 2 (closed loop), the pitch target in degrees,
        % and SAS on or off. Its reply arrives as the Lua values CG_MODE etc.
        sendScriptCommand(obj, mode, targetDeg, sas)
        % Send a line of text to the Cube, which writes it into its own log.
        sendText(obj, text)
        % Restart the Cube, as if it were powered off and on. Afterwards its
        % safety switch is on again, and some parameters (SCR_ENABLE) take effect.
        reboot(obj)
    end

    methods (Abstract, Access = protected)
        sendServo(obj, output, pwm)
    end

    methods
        function setServoLimits(obj, output, minPwm, maxPwm)
            arguments
                obj
                output (1,1) double {mustBeInteger, mustBeBetween(output, 1, 16)}
                minPwm (1,1) double {mustBeFinite}
                maxPwm (1,1) double {mustBeFinite}
            end
            problem = DataSource.limitsProblem(minPwm, (minPwm + maxPwm) / 2, maxPwm);
            if problem ~= ""
                error("CubeGUI:limits", "Output %d: %s", output, problem)
            end
            obj.ServoLimits(output, :) = [minPwm maxPwm];
        end

        function clearServoLimits(obj, output)
            % Stop driving this output until it has limits again.
            obj.ServoLimits(output, :) = NaN;
        end

        function pwm = setServo(obj, output, pwm)
            % Clamp pwm to the output's limits, send it, and return what was sent.
            arguments
                obj
                output (1,1) double {mustBeInteger, mustBeBetween(output, 1, 16)}
                pwm (1,1) double   % checked below, after the clearer messages
            end
            if ~obj.IsConnected
                error("CubeGUI:notConnected", "Not connected, so nothing was sent.")
            end
            limits = obj.ServoLimits(output, :);
            if any(isnan(limits))
                error("CubeGUI:noLimits", ['CubeGUI has no usable PWM limits for output %d ' ...
                    '(SERVO%d_MIN and _MAX on the Cube), so it won''t drive it. See the Setup tab.'], ...
                    output, output)
            end
            if ~isfinite(pwm)
                error("CubeGUI:badPwm", "Output %d: the PWM to send isn't a number.", output)
            end
            pwm = round(min(max(pwm, limits(1)), limits(2)));
            obj.sendServo(output, pwm);
            obj.Commanded(output) = pwm;
            obj.Telemetry.addCommand(output, pwm);
        end

        function delete(obj)
            % Runs when the object is deleted: make sure nothing is left running.
            if obj.IsConnected
                obj.disconnect();
            end
        end
    end

    methods (Static)
        function problem = limitsProblem(minPwm, trimPwm, maxPwm)
            % "" if these limits are usable, or else what's wrong with them,
            % in a few words.
            low = DataSource.HardMinPwm;
            high = DataSource.HardMaxPwm;
            if any(isnan([minPwm, trimPwm, maxPwm]))
                problem = "not all read from the Cube yet";
            elseif minPwm < low || maxPwm > high
                problem = string(sprintf("limits %g to %g µs go outside %d to %d µs", ...
                    minPwm, maxPwm, low, high));
            elseif ~(minPwm < trimPwm && trimPwm < maxPwm)
                problem = string(sprintf("needs MIN < TRIM < MAX, but they're %g, %g and %g", ...
                    minPwm, trimPwm, maxPwm));
            else
                problem = "";
            end
        end
    end
end
