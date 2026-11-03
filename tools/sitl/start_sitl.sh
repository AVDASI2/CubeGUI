#!/bin/bash
# Start ArduPlane SITL (ArduPilot's simulator) with lua/cubegui.lua loaded,
# for testing CubeGUI and the script without a Cube. See README.md here.
#
#   tools/sitl/start_sitl.sh [path/to/arduplane]
#
# SITL's port 0 sends to 127.0.0.1:14575, where kahuna_relay.py passes it
# on to CubeGUI as the Kahuna would. Port 1 sends to 127.0.0.1:14571, for
# test_cubegui_lua.py.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
arduplane="${1:-${ARDUPLANE:-$HOME/ardupilot/build/sitl/bin/arduplane}}"
ardupilot="${ARDUPILOT:-$HOME/ardupilot}"
run="$here/run"
mkdir -p "$run/scripts"
cp "$repo/lua/cubegui.lua" "$run/scripts/"
cat > "$run/cubegui-sitl.parm" <<PARAMS
SCR_ENABLE 1
LOG_DISARMED 1
SERVO5_FUNCTION 0
SERVO6_FUNCTION 0
SERVO7_FUNCTION 0
THR_FAILSAFE 2
PARAMS
cd "$run"
exec "$arduplane" --model plane --speedup 1 -I0 \
  --defaults "$ardupilot/Tools/autotest/models/plane.parm,$run/cubegui-sitl.parm" \
  --serial0 udpclient:127.0.0.1:14575 --serial1 udpclient:127.0.0.1:14571
