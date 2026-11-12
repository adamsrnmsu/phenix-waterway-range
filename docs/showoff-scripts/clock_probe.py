import socket, time, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); out = []
for i in range(10):
    t = time.time(); s.sendto(b"clk%d" % i, ("10.1.1.102", 9)); out.append(t); time.sleep(0.3)
print("GUEST", " ".join("%.6f" % t for t in out))
