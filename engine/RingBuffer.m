classdef RingBuffer < handle
    %RINGBUFFER  Keeps the most recent samples of a signal, up to a fixed number.
    %
    %   buf = RingBuffer(600, 1);   % room for 600 samples of 1 value each
    %   buf.push(t, y)              % add a sample (t: time in s, y: a row of values)
    %   [t, y] = buf.data();        % everything held, oldest first
    %
    %   Once it's full, each new sample overwrites the oldest, so memory use
    %   never grows however long CubeGUI runs. It's like Python's
    %   collections.deque(maxlen=600), but with the storage set aside up
    %   front, which keeps it fast enough to fill from message callbacks.
    %
    %   "< handle" makes this a handle class: every variable that holds it
    %   points at the same object, as with Python objects. Without it, MATLAB
    %   would copy the buffer whenever it's passed to a function, and a
    %   callback adding samples would only be changing its own copy.

    properties (SetAccess = private)
        Capacity    % the most samples it can hold
        Count = 0   % how many it holds now
    end

    properties (Access = private)
        Times       % Capacity x 1 column of times
        Values      % Capacity x Width matrix, one row per sample
        Next = 1    % the row the next sample goes into
    end

    methods
        function obj = RingBuffer(capacity, width)
            arguments
                capacity (1,1) double {mustBeInteger, mustBePositive}
                width (1,1) double {mustBeInteger, mustBePositive} = 1
            end
            obj.Capacity = capacity;
            obj.Times = NaN(capacity, 1);
            obj.Values = NaN(capacity, width);
        end

        function push(obj, t, values)
            % Add one sample, overwriting the oldest if the buffer is full.
            obj.Times(obj.Next) = t;
            obj.Values(obj.Next, :) = values;
            obj.Next = mod(obj.Next, obj.Capacity) + 1;   % wrap round to 1
            obj.Count = min(obj.Count + 1, obj.Capacity);
        end

        function [t, values] = data(obj)
            % Everything held, oldest first, as copies the caller can keep.
            if obj.Count < obj.Capacity
                order = 1:obj.Count;
            else
                % Full: the oldest sample is the one about to be overwritten.
                order = [obj.Next:obj.Capacity, 1:obj.Next-1];
            end
            t = obj.Times(order);
            values = obj.Values(order, :);
        end

        function clear(obj)
            % Forget everything, e.g. after reconnecting to a rebooted Cube.
            obj.Times(:) = NaN;
            obj.Values(:) = NaN;
            obj.Next = 1;
            obj.Count = 0;
        end
    end
end
