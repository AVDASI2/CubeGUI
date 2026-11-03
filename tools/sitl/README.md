# Testing with ArduPilot's simulator (SITL)

SITL ("software in the loop") is ArduPilot's own code running on a laptop as a simulated aircraft. Unlike `tools/fake_cube.py`, it *is* ArduPlane, so it answers exactly as a Cube would, and it runs Lua scripts. It's how `lua/cubegui.lua` was tested before it had been near a real Cube.

This is for developing CubeGUI, not something students need.

## Building it (once, about 5 minutes)

From an ArduPilot checkout (here `~/ardupilot`), build into a separate folder with its own lock file, so an existing Cube build there isn't disturbed:

```bash
cd ~/ardupilot
export WAFLOCK=.lock-waf_cubegui_sitl
./waf configure --board sitl --out /tmp/cubegui-sitl
./waf --out /tmp/cubegui-sitl plane
```

The program is then `/tmp/cubegui-sitl/sitl/bin/arduplane`.

To test a particular release, e.g. **ArduPlane 4.6.3** (likely on the kits), make a local clone at that tag, borrow the submodules from the existing checkout (no download needed), and build it the same way:

```bash
git clone --shared --no-checkout ~/ardupilot /tmp/ap46
cd /tmp/ap46
git checkout Plane-4.6.3
for m in modules/waf modules/mavlink modules/DroneCAN/DSDL modules/DroneCAN/dronecan_dsdlc modules/DroneCAN/libcanard modules/DroneCAN/pydronecan; do git config submodule.$m.url ~/ardupilot/$m; done
git -c protocol.file.allow=always submodule update --init modules/waf modules/mavlink modules/DroneCAN/DSDL modules/DroneCAN/dronecan_dsdlc modules/DroneCAN/libcanard modules/DroneCAN/pydronecan
./waf configure --board sitl
./waf plane
```

Then start it with `ARDUPILOT=/tmp/ap46 tools/sitl/start_sitl.sh /tmp/ap46/build/sitl/bin/arduplane`.

## Running it

Three terminals, from the CubeGUI folder:

1. Start SITL, with `cubegui.lua` in its scripts folder:

   ```bash
   tools/sitl/start_sitl.sh /tmp/cubegui-sitl/sitl/bin/arduplane
   ```

2. Start the relay, which plays the Kahuna's part so CubeGUI can talk to SITL on its usual desk ports (it listens on 14561 and sends to 14565):

   ```bash
   .venv/bin/python tools/sitl/kahuna_relay.py
   ```

3. Run the script's tests:

   ```bash
   .venv/bin/python tools/sitl/test_cubegui_lua.py
   ```

   then CubeGUI end to end (14 checks), in MATLAB from the CubeGUI folder:

   ```matlab
   run("tools/sitl/test_cubegui_end_to_end.m")
   ```

   and the Logs panel's Cube log controls, the log download and installing `cubegui.lua` (8 checks, a few minutes):

   ```matlab
   run("tools/sitl/test_logs_and_upload.m")
   ```

   Or open CubeGUI yourself with a settings file that has `localPort` 14561, `cubeAddress` 127.0.0.1 and `cubePort` 14565, and choose **Cube (Wi-Fi)**.

4. **Cube (USB):** use `usb_relay.py` instead of `kahuna_relay.py` (they share SITL's port, so not both). It gives SITL a pseudo serial port, as a USB cable would, and writes its name to the file you give it:

   ```bash
   python3 tools/sitl/usb_relay.py /tmp/usb_port
   ```

   then, in MATLAB (7 checks: the port labelled MAVLink, heartbeats, parameters, pitch at 20 Hz, a servo command and the log list, all over the serial port):

   ```matlab
   run("tools/sitl/test_usb_connection.m")
   ```

   macOS and Linux only. The firmware uploader can't be tried on SITL, which has no bootloader: `tests/FakeBootloader.m` stands in for one in the MATLAB tests.

SITL keeps its parameters in `tools/sitl/run/eeprom.bin`. Delete the `run` folder to start afresh.

## What the tests check

`test_cubegui_lua.py` checks 30 things on the running script, and sets `RC8_OPTION` and `RC9_OPTION` back to 0 when it's done:

- it starts and reports;
- **CubeGUI mode:** `DO_SET_SERVO` works;
- **closed loop:** the script drives the elevator, CubeGUI's commands are ignored, and the target's direction is right;
- **back to CubeGUI:** its commands work again;
- **RC mode from a switch:** sticks drive their outputs within `SERVOn_MIN`/`MAX`, follow a changed limit, and honour `SERVOn_REVERSED` with uneven limits;
- the switches found by `RCn_OPTION`: the SAS switch, all three mode switch positions (middle changes nothing), the switch already low when the script starts, no switch at all, and `CGUI_ENABLE = 0`;
- **losing the RC signal** (`SIM_RC_FAIL`) with `THR_FAILSAFE = 2`.

`test_logs_and_upload.m` checks that `LOG_DISARMED` starts the Cube's log, that setting it to 0 stops the file growing, and that starting again carries on in the same file; that the newest log downloads complete, as a `.BIN` file; and that `cubegui.lua` copies over MAVFTP byte for byte, and the script reports again after the restart. SITL sends logs at USB speed, so its download time isn't a guide to the Wi-Fi.

Last run, 2026-11-03, against ArduPlane 4.8-dev: 30 of 30, 14 of 14, and 8 of 8. `test_usb_connection.m`: 6 of 6 on 2026-11-04. (On 2026-11-01 the first two also passed against ArduPlane 4.6.3.)
