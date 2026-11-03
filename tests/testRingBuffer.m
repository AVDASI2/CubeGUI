function tests = testRingBuffer
%TESTRINGBUFFER  Automated checks for engine/RingBuffer.m.
%
%   Run with:  runtests("tests")
%
%   Each function below starting with "test" is one check, like pytest.
tests = functiontests(localfunctions);
end

function setupOnce(~)
addpath(fullfile(fileparts(mfilename("fullpath")), "..", "engine"));
end

function testStartsEmpty(tc)
buf = RingBuffer(3);
[t, y] = buf.data();
verifyEmpty(tc, t)
verifyEmpty(tc, y)
verifyEqual(tc, buf.Count, 0)
end

function testKeepsOrderBeforeFull(tc)
buf = RingBuffer(3);
buf.push(1, 10)
buf.push(2, 20)
[t, y] = buf.data();
verifyEqual(tc, t, [1; 2])
verifyEqual(tc, y, [10; 20])
end

function testOverwritesOldestWhenFull(tc)
buf = RingBuffer(3);
for k = 1:5
    buf.push(k, 10 * k)
end
[t, y] = buf.data();
verifyEqual(tc, t, [3; 4; 5])
verifyEqual(tc, y, [30; 40; 50])
verifyEqual(tc, buf.Count, 3)
end

function testExactlyFull(tc)
buf = RingBuffer(3);
for k = 1:3
    buf.push(k, k)
end
verifyEqual(tc, buf.data(), [1; 2; 3])
end

function testSeveralValuesPerSample(tc)
buf = RingBuffer(2, 3);
buf.push(1, [1 2 3])
buf.push(2, [4 5 6])
buf.push(3, [7 8 9])
[t, y] = buf.data();
verifyEqual(tc, t, [2; 3])
verifyEqual(tc, y, [4 5 6; 7 8 9])
end

function testClear(tc)
buf = RingBuffer(3);
buf.push(1, 1)
buf.clear()
verifyEqual(tc, buf.Count, 0)
buf.push(2, 2)
verifyEqual(tc, buf.data(), 2)
end
