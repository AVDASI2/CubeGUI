function panel = markerPanel(parent, cube, options)
%MARKERPANEL  Marks a moment, e.g. "run 3: 10 m/s, AoA 4", in both logs.
%
%   In config/cubegui.json, under "controls":
%       {"panel": "markerPanel", "level": 1}
%
%   Type a note and click Mark (or press Return). The note goes in the
%   "marker" column of CubeGUI's log and, as a MSG, in the Cube's own log,
%   so the two logs (and your notes) can be lined up afterwards.

box = uipanel(parent, Title="Run marker");
grid = uigridlayout(box, [1 2], ColumnWidth={"1x", 70}, Padding=[8 4 8 4]);
note = uieditfield(grid, "text", Placeholder="e.g. run 3: 10 m/s, AoA 4");
uibutton(grid, Text="Mark", ButtonPushedFcn=@(~, ~) markAndClear(cube, note));
note.ValueChangedFcn = @(~, ~) markAndClear(cube, note);   % Return does it too

panel.height = 60;   % in pixels. No panel.update: nothing here changes by itself.
end

function markAndClear(cube, note)
cube.mark(note.Value);
note.Value = "";
end
