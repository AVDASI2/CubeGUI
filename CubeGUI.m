function app = CubeGUI(options)
%CUBEGUI  Open the CubeGUI window.
%
%   CubeGUI                                  % settings from config/cubegui.json
%   CubeGUI(ConfigFile="config/kit7.json")   % a different settings file
%   CubeGUI(Level=1)                         % open at another capability level
%   CubeGUI(Demo=true)                       % with a drop-down to change level live
%
%   To close it, close the window. That disconnects and stops everything.

arguments
    options.ConfigFile (1,1) string = fullfile(fileparts(mfilename("fullpath")), ...
        "config", "cubegui.json")
    options.Level double {mustBeScalarOrEmpty} = []
    options.Demo (1,1) logical = false
end

% CubeGUI's engine (the parts students don't need to change) is in the engine
% folder, and the parts of the window they can copy and change are in panels.
root = fileparts(mfilename("fullpath"));
addpath(fullfile(root, "engine"), fullfile(root, "panels"));

config = loadConfig(options.ConfigFile);
if ~isempty(options.Level)
    if ~ismember(options.Level, [levels().number])
        error("CubeGUI:level", "Level must be a whole number from 0 to %d.", max([levels().number]))
    end
    config.level = options.Level;
end
config.demo = options.Demo;
% A log folder like "logs" means the logs folder inside CubeGUI's own folder.
if ~isAbsolutePath(config.logging.folder)
    config.logging.folder = fullfile(root, config.logging.folder);
end
a = CubeGuiApp(config);

% Only hand the app back if asked (app = CubeGUI), so typing plain CubeGUI
% doesn't print a long description of it.
if nargout > 0
    app = a;
end
end

function tf = isAbsolutePath(folder)
% True for /Users/..., ~/..., C:\... or \\server\... ; false for "logs".
tf = startsWith(folder, ["/", "~", "\\"]) || ~isempty(regexp(folder, "^[A-Za-z]:[\\/]", "once"));
end
