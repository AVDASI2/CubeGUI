"""Play a USB cable's part between SITL and CubeGUI (level 4's Cube (USB)).

SITL sends to us on 14575 (udpclient), as for kahuna_relay.py. We pass its
packets to a pseudo serial port, and pass whatever CubeGUI writes to that
port back to SITL. Prints the port's name (e.g. /dev/ttys003), and writes
it to the file given as the first argument, if any. Use one relay or the
other, not both: they share SITL's port. macOS and Linux only.
"""
import os, pty, select, socket, sys, tty
master, slave = pty.openpty()
tty.setraw(slave)
name = os.ttyname(slave)
print(name, flush=True)
if len(sys.argv) > 1:
    with open(sys.argv[1], "w") as f:
        f.write(name)
sitl_side = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sitl_side.bind(("127.0.0.1", 14575))
sitl_addr = None
while True:
    ready, _, _ = select.select([sitl_side, master], [], [])
    if sitl_side in ready:
        data, sitl_addr = sitl_side.recvfrom(4096)
        os.write(master, data)
    if master in ready:
        data = os.read(master, 4096)
        if sitl_addr:
            sitl_side.sendto(data, sitl_addr)
