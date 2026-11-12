# ground-truth sampler: runs on rtu-1, reads every provider tag via ZMQ REQ, writes "epoch,tag,reply" CSV.
import zmq, time, sys
dur = float(sys.argv[1]); out = open(sys.argv[2], "w", buffering=1)
tags = "lowerwater.height lock.height lowergate.open lowervalve.open lowersensor.active lowersensor.direction locksensor.active locksensor.direction boat.location boat.direction upperwater.height uppergate.open uppervalve.open uppersensor.active uppersensor.direction".split()
c = zmq.Context(); s = c.socket(zmq.REQ); s.setsockopt(zmq.RCVTIMEO, 2000); s.setsockopt(zmq.LINGER, 0); s.connect("tcp://172.16.1.2:5555")
t0 = time.time()
while time.time() - t0 < dur:
    for t in tags:
        ts = time.time(); s.send(b"READ=" + t.encode() + b"\x00")
        try: r = s.recv().decode().strip("\x00 ").replace("ACK=","").replace(",", ";")
        except zmq.Again:
            s.close(); s = c.socket(zmq.REQ); s.setsockopt(zmq.RCVTIMEO, 2000); s.setsockopt(zmq.LINGER, 0); s.connect("tcp://172.16.1.2:5555"); r = "TIMEOUT"
        out.write("%.4f,%s,%s\n" % (ts, t, r))
    time.sleep(0.2)
