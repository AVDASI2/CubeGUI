"""Play the Kahuna's part between SITL and CubeGUI.

SITL sends to us on 14575 (udpclient). We pass its packets to CubeGUI on
14561, sending from 14565 like the Kahuna does, and pass CubeGUI's packets
back to wherever SITL last sent from.
"""
import select, socket
sitl_side = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sitl_side.bind(("127.0.0.1", 14575))
gcs_side = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); gcs_side.bind(("127.0.0.1", 14565))
sitl_addr = None
while True:
    ready, _, _ = select.select([sitl_side, gcs_side], [], [])
    for s in ready:
        data, addr = s.recvfrom(4096)
        if s is sitl_side:
            sitl_addr = addr
            gcs_side.sendto(data, ("127.0.0.1", 14561))
        elif sitl_addr:
            sitl_side.sendto(data, sitl_addr)
