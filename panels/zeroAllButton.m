function panel = zeroAllButton(parent, cube, options)
%ZEROALLBUTTON  A button that sends every servo back to its trim position.
%
%   In config/cubegui.json, under "controls":
%       {"panel": "zeroAllButton"}
%       {"panel": "zeroAllButton", "text": "Centre everything"}
%
%   This is the simplest panel, so it's the one to copy to make a button
%   of your own: see docs/recipes.md.

text = "Zero all (send every servo to trim)";
if isfield(options, "text")     % the settings file can change the button's words
    text = options.text;
end

% When it's pressed, ask the Cube to send every servo to trim.
uibutton(parent, Text=text, ButtonPushedFcn=@(~, ~) cube.zeroAll());

panel.height = 36;   % in pixels. No panel.update: nothing here changes.
end
