function tests = testServoMapping
%TESTSERVOMAPPING  Checks every way of turning a slider value into PWM.
%
%   Run with:  runtests("tests")
tests = functiontests(localfunctions);
end

function setupOnce(~)
addpath(fullfile(fileparts(mfilename("fullpath")), "..", "engine"));
end

function s = servo(varargin)
% A servo's settings, with extra entries given as name, value pairs.
s = struct("name", "Test", "output", 5, "minPwm", 1100, "trimPwm", 1500, "maxPwm", 1900);
for k = 1:2:numel(varargin)
    s.(varargin{k}) = varargin{k + 1};
end
end

function testPwmIsTheDefault(tc)
% Without a mapping, the slider is the PWM itself, from MIN to MAX.
m = ServoMapping(servo());
verifyEqual(tc, m.Type, "pwm")
verifyEqual(tc, m.Units, "µs")
verifyEqual(tc, m.Range, [1100 1900])
verifyEqual(tc, [m.toPwm(1100) m.toPwm(1500) m.toPwm(1620.4)], [1100 1500 1620])
verifyEqual(tc, m.toValue(1700), 1700)
end

function testPercent(tc)
m = ServoMapping(servo("mapping", struct("type", "percent")));
verifyEqual(tc, m.Range, [-100 100])
verifyEqual(tc, [m.toPwm(-100) m.toPwm(0) m.toPwm(50) m.toPwm(100)], [1100 1500 1700 1900])
end

function testPercentUnevenTrim(tc)
% Each side scales separately, so 0 % is always trim.
m = ServoMapping(servo("minPwm", 1000, "trimPwm", 1600, "maxPwm", 1800, ...
    "mapping", struct("type", "percent")));
verifyEqual(tc, [m.toPwm(-50) m.toPwm(0) m.toPwm(50)], [1300 1600 1700])
end

function testHeldAtRangeEnds(tc)
m = ServoMapping(servo());
verifyEqual(tc, m.toPwm(2500), 1900)
verifyEqual(tc, m.toPwm(500), 1100)
end

function testTable(tc)
m = ServoMapping(servo("units", "deg", "mapping", ...
    struct("type", "table", "points", [-20 1150; 0 1500; 10 1700; 25 1880])));
verifyEqual(tc, m.Range, [-20 25])
verifyEqual(tc, m.toPwm(0), 1500)
verifyEqual(tc, m.toPwm(5), 1600)       % halfway between 0 and 10 degrees
verifyEqual(tc, m.toPwm(-10), 1325)
verifyEqual(tc, m.toValue(1600), 5, AbsTol=0.05)
end

function testLinear(tc)
m = ServoMapping(servo("units", "deg", "range", [-20 20], ...
    "mapping", struct("type", "linear", "m", 20, "c", 1500)));
verifyEqual(tc, m.toPwm(10), 1700)
verifyEqual(tc, m.toValue(1300), -10, AbsTol=0.05)
end

function testDecreasingLinear(tc)
% A servo mounted the other way round: more degrees, less PWM.
m = ServoMapping(servo("units", "deg", "range", [-20 20], ...
    "mapping", struct("type", "linear", "m", -20, "c", 1500)));
verifyEqual(tc, m.toPwm(10), 1300)
verifyEqual(tc, m.toValue(1300), 10, AbsTol=0.05)
end

function testExponential(tc)
m = ServoMapping(servo("units", "deg", "range", [0 10], ...
    "mapping", struct("type", "exponential", "a", 100, "b", 0.1, "c", 1400)));
verifyEqual(tc, m.toPwm(0), 1500)
verifyEqual(tc, m.toPwm(10), round(100 * exp(1) + 1400))
end

function testCustom(tc)
m = ServoMapping(servo("units", "deg", "range", [-10 10], ...
    "mapping", struct("type", "custom", "expression", "1500 + 20*x + 0.5*x^2")));
verifyEqual(tc, m.toPwm(4), 1500 + 80 + 8)
end

function testCustomRejectsOtherCode(tc)
for expr = ["system('rm -rf ~')", "delete(x)", "1500 + y", "eval('1')"]
    verifyError(tc, @() ServoMapping(servo("units", "deg", "range", [-10 10], ...
        "mapping", struct("type", "custom", "expression", expr))), "CubeGUI:mapping", ...
        "Should refuse: " + expr)
end
end

function testCustomAllowsScientificNumbers(tc)
m = ServoMapping(servo("units", "deg", "range", [-10 10], ...
    "mapping", struct("type", "custom", "expression", "1.5e3 + 2E1*x")));
verifyEqual(tc, m.toPwm(1), 1520)
end

function testMustBeOneWay(tc)
% A mapping that goes up then down would make one PWM mean two positions.
verifyError(tc, @() ServoMapping(servo("units", "deg", "range", [-10 10], ...
    "mapping", struct("type", "custom", "expression", "1500 + 5*x^2"))), "CubeGUI:mapping")
end

function testMissingPiecesNamed(tc)
verifyError(tc, @() ServoMapping(servo("units", "deg", "range", [-10 10], ...
    "mapping", struct("type", "linear", "m", 20))), "CubeGUI:mapping")
verifyError(tc, @() ServoMapping(servo("range", [-10 10], ...
    "mapping", struct("type", "linear", "m", 20, "c", 1500))), "CubeGUI:mapping")
verifyError(tc, @() ServoMapping(servo("mapping", struct("type", "wiggly"))), "CubeGUI:mapping")
end
