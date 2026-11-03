"""Test lua/cubegui.lua on ArduPlane SITL: modes, switches, limits, reversing, RC loss.

Run start_sitl.sh first (see README.md here), then:
    .venv/bin/python tools/sitl/test_cubegui_lua.py

Talks to SITL's second port (udpclient to 14571) as a ground station with
system ID 255 (RC overrides are only accepted from SYSID_MYGCS, 255).
"""
import os, sys, time
os.environ["MAVLINK20"] = "1"
from pymavlink import mavutil

m = mavutil.mavlink_connection("udpin:127.0.0.1:14571", source_system=255, source_component=190)
mav = m.mav
state = {"named": {}, "servo": [0] * 17, "texts": []}
override = {}          # channel -> pwm, re-sent continuously
results = []


def pump(seconds):
    end = time.time() + seconds
    next_hb = 0
    while time.time() < end:
        if time.time() >= next_hb:
            mav.heartbeat_send(6, 8, 0, 0, 0)
            send_override()
            next_hb = time.time() + 0.2
        msg = m.recv_match(blocking=True, timeout=0.05)
        while msg:
            t = msg.get_type()
            if t == "NAMED_VALUE_FLOAT":
                state["named"][msg.name] = msg.value
            elif t == "SERVO_OUTPUT_RAW":
                for k in range(1, 17):
                    state["servo"][k] = getattr(msg, f"servo{k}_raw", 0)
            elif t == "STATUSTEXT":
                state["texts"].append(msg.text)
            msg = m.recv_match(blocking=False)


def send_override():
    if not override:
        return
    vals = [65535] * 18                      # 65535: leave this channel alone
    for ch, pwm in override.items():
        vals[ch - 1] = pwm
    mav.rc_channels_override_send(1, 1, *vals)


def set_param(name, value):
    for _ in range(5):
        mav.param_set_send(1, 1, name.encode(), float(value), mavutil.mavlink.MAV_PARAM_TYPE_REAL32)
        p = m.recv_match(type="PARAM_VALUE", blocking=True, timeout=1)
        if p and p.param_id == name and abs(p.param_value - value) < 1e-3:
            return
    raise RuntimeError("couldn't set " + name)


def gui_command(mode, target=0.0, sas=0):
    mav.command_long_send(1, 1, 31010, 0, mode, target, sas, 0, 0, 0, 0)


def set_servo(out, pwm):
    mav.command_long_send(1, 1, mavutil.mavlink.MAV_CMD_DO_SET_SERVO, 0, out, pwm, 0, 0, 0, 0, 0)


def check(name, ok, detail=""):
    results.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)


def stream():
    # SERVO_OUTPUT_RAW and NAMED_VALUE_FLOAT on this link, 10 Hz.
    for msg_id in (36,):
        mav.command_long_send(1, 1, 511, 0, msg_id, 100000, 0, 0, 0, 0, 0)


# ---- start from a known state ----------------------------------------------------
pump(1)
stream()
for name, value in [("CGUI_ENABLE", 1), ("CGUI_MODE_FUNC", 300), ("CGUI_SAS_FUNC", 301),
                    ("RC8_OPTION", 0), ("RC9_OPTION", 0), ("CGUI_ELEV_OUT", 5),
                    ("SERVO5_MIN", 1100), ("SERVO5_TRIM", 1500), ("SERVO5_MAX", 1900),
                    ("SERVO5_REVERSED", 0), ("SERVO6_MIN", 1100), ("SERVO6_MAX", 1900)]:
    set_param(name, value)
# Restart the scripts, so the newest cubegui.lua is running (MAV_CMD_SCRIPTING, stop and restart).
state["texts"].clear()
mav.command_long_send(1, 1, 42701, 0, 3, 0, 0, 0, 0, 0, 0)
pump(4)
stream()
check("script starts and reports", "CG_MODE" in state["named"] and any("cubegui.lua running" in t for t in state["texts"]),
      str(state["texts"][-3:]))
pump(3)
check("no deprecation or error messages", not any(("cubegui" in t.lower() and "running" not in t) or "get_pitch" in t
                                               for t in state["texts"]), str(state["texts"][-3:]))

# ---- GUI mode --------------------------------------------------------------------
gui_command(0)
set_servo(5, 1700)
pump(1.5)
check("GUI mode: CG_MODE 0", state["named"].get("CG_MODE") == 0)
check("GUI mode: DO_SET_SERVO drives output 5", state["servo"][5] == 1700, f"out5={state['servo'][5]}")

# ---- closed loop chosen by CubeGUI -------------------------------------------------
gui_command(2, 10.0)
pump(2)
out_cl = state["servo"][5]
check("closed loop: CG_MODE 2, CG_TGT 10", state["named"].get("CG_MODE") == 2 and state["named"].get("CG_TGT") == 10,
      str(state["named"]))
check("closed loop: the script drives the elevator", out_cl not in (0, 1700) and 1100 <= out_cl <= 1900,
      f"out5={out_cl}, CG_ELEV={state['named'].get('CG_ELEV')}")
set_servo(5, 1200)
pump(1)
check("closed loop: CubeGUI's DO_SET_SERVO is ignored", state["servo"][5] != 1200, f"out5={state['servo'][5]}")
gui_command(2, -10.0)
pump(3)
check("closed loop: a nose-down target moves the elevator below trim", state["servo"][5] < 1500,
      f"out5={state['servo'][5]}")

# ---- back to GUI ----------------------------------------------------------------------
gui_command(0)
pump(1)
set_servo(5, 1650)
pump(1)
check("back in GUI mode, DO_SET_SERVO works again", state["named"].get("CG_MODE") == 0 and state["servo"][5] == 1650,
      f"mode={state['named'].get('CG_MODE')} out5={state['servo'][5]}")

# ---- RC mode from the transmitter's switch ---------------------------------------------
# The mode switch is whichever channel has RCn_OPTION = 300 (here 8): low RC, high CubeGUI.
set_param("RC8_OPTION", 300)
override.update({8: 1100, 2: 2000, 4: 1000})     # switch low: RC; sticks at the ends of SITL's calibration (1000-2000)
pump(2)
check("RC mode: CG_MODE 1", state["named"].get("CG_MODE") == 1, str(state["named"]))
check("RC mode: elevator stick full -> SERVO5_MAX", abs(state["servo"][5] - 1900) <= 5, f"out5={state['servo'][5]}")
check("RC mode: rudder stick full the other way -> SERVO6_MIN", abs(state["servo"][6] - 1100) <= 5,
      f"out6={state['servo'][6]}")
set_param("SERVO5_MAX", 1800)
pump(1)
check("RC mode: honours a new SERVO5_MAX", abs(state["servo"][5] - 1800) <= 5, f"out5={state['servo'][5]}")
set_param("SERVO5_REVERSED", 1)
pump(1)
check("RC mode: honours SERVO5_REVERSED with uneven limits (full up stick -> MIN)", abs(state["servo"][5] - 1100) <= 5,
      f"out5={state['servo'][5]}")
set_param("SERVO5_REVERSED", 0)
set_param("SERVO5_MAX", 1900)
set_servo(5, 1300)
pump(1)
check("RC mode: CubeGUI's DO_SET_SERVO is ignored", state["servo"][5] != 1300, f"out5={state['servo'][5]}")

# ---- SAS switch: RCn_OPTION = 301 (here 9), low off, high on, middle no change -------------------
set_param("RC9_OPTION", 301)
override[9] = 1900
pump(1)
check("SAS switch high: CG_SAS 1", state["named"].get("CG_SAS") == 1)
override[9] = 1100
pump(1)
check("SAS switch low: CG_SAS 0", state["named"].get("CG_SAS") == 0)
gui_command(0, 0.0, 1)
override[9] = 1500
pump(1)
check("SAS switch middle: no change (still 0, even if CubeGUI asks)", state["named"].get("CG_SAS") == 0)
gui_command(0)

# ---- mode switch positions --------------------------------------------------------------------
override[8] = 1900
pump(1.5)
check("switch high: CubeGUI chooses (GUI)", state["named"].get("CG_MODE") == 0)
gui_command(2, 5.0)
pump(1.5)
check("switch high: CubeGUI can choose closed loop", state["named"].get("CG_MODE") == 2)
override[8] = 1500
pump(1.5)
check("switch middle after high: no change (closed loop)", state["named"].get("CG_MODE") == 2)
override[8] = 1100
pump(1.5)
check("switch low: RC, even in closed loop", state["named"].get("CG_MODE") == 1)
override[8] = 1500
pump(1.5)
check("switch middle after low: no change (RC)", state["named"].get("CG_MODE") == 1)
gui_command(0)

# ---- switch already low when the script starts -------------------------------------------------
override[8] = 1100
pump(0.5)
mav.command_long_send(1, 1, 42701, 0, 3, 0, 0, 0, 0, 0, 0)   # restart the scripts
state["named"].pop("CG_MODE", None)
pump(4)
stream()
pump(1)
check("switch low at start: RC straight away, without moving it", state["named"].get("CG_MODE") == 1,
      str(state["named"]))

# ---- no channel with RCn_OPTION = 300 ------------------------------------------------------------
set_param("RC8_OPTION", 0)
pump(1.5)
check("no mode switch: CubeGUI chooses", state["named"].get("CG_MODE") == 0)
set_param("RC8_OPTION", 300)

# ---- CGUI_ENABLE = 0 --------------------------------------------------------------------------
override[8] = 1100
set_param("CGUI_ENABLE", 0)
pump(1.5)
check("CGUI_ENABLE 0: GUI mode whatever the switch says", state["named"].get("CG_MODE") == 0)
set_param("CGUI_ENABLE", 1)

# ---- RC lost ------------------------------------------------------------------------------------
pump(1.5)
check("RC mode again before the loss", state["named"].get("CG_MODE") == 1)
override.clear()
mav.rc_channels_override_send(1, 1, *([0] * 18))   # release every override
set_param("SIM_RC_FAIL", 1)                         # the simulated receiver stops sending pulses
pump(4)
check("RC lost: CG_RC 0", state["named"].get("CG_RC") == 0, str(state["named"]))
check("RC lost: out of RC mode", state["named"].get("CG_MODE") != 1, str(state["named"]))
set_param("SIM_RC_FAIL", 0)
pump(3)
check("RC back: CG_RC 1", state["named"].get("CG_RC") == 1, str(state["named"]))

# Tidy up, so CubeGUI (or the end-to-end test) finds no switches set.
for name in ("RC8_OPTION", "RC9_OPTION"):
    set_param(name, 0)

print(f"\n{sum(ok for _, ok in results)} of {len(results)} passed")
print("recent statustext:", state["texts"][-6:])
sys.exit(0 if all(ok for _, ok in results) else 1)
