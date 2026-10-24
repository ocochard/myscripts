#!/usr/bin/env python3
"""Full timeline of the two static-MG crews: liveness, seat, and where the survivor goes."""
import json, socket, sys, time

PORT = int(sys.argv[1])
DUR = float(sys.argv[2]) if len(sys.argv) > 2 else 300.0

s = socket.create_connection(("127.0.0.1", PORT), timeout=30)
f = s.makefile("rwb")


def ev(code):
    f.write((json.dumps({"cmd": "eval", "code": code}) + "\n").encode())
    f.flush()
    while True:
        line = f.readline().decode().strip()
        if not line:
            return "<eof>"
        try:
            j = json.loads(line)
        except Exception:
            return "RAW:" + line
        if "event" in j:
            continue
        return j.get("result", j)


while True:
    t = ev('format["%1", time]').strip('"')
    try:
        if float(t) > 1.0:
            break
    except ValueError:
        pass
    time.sleep(1)

print("bind at t =", t, ":", ev(
    'mgL = nearestObject [[8402.13,9870.81,8.97],"M2StaticMGE"]; '
    'mgF = nearestObject [[8195.24,9874.84,25.56],"M2StaticMGE"]; '
    'manL = gunner mgL; manF = gunner mgF; '
    'format["crewL=%1 crewF=%2", manL, manF]'), flush=True)

# The bug needs one gunner dead. Waiting for the firefight to do it is flaky
# (a 300 s run can end with both alive), so kill the leader's crew outright
# unless the caller wants to observe a natural death.
MODE = sys.argv[4] if len(sys.argv) > 4 else "forced"
KILL_DELAY = float(MODE) if MODE.replace(".", "").isdigit() else 0.0

t0 = time.time()
killed = MODE == "natural"
if killed:
    print("kill: skipped (natural mode)", flush=True)
elif KILL_DELAY <= 0:
    print("kill:", ev('manL setDammage 1; format["Lalive=%1", alive manL]'), flush=True)
    killed = True
while time.time() - t0 < DUR:
    if not killed and time.time() - t0 >= KILL_DELAY:
        print("kill:", ev('manL setDammage 1; format["Lalive=%1", alive manL]'), flush=True)
        killed = True
    print(ev('format["t=%1 Lalive=%2 Lin=%3 Falive=%4 Fin=%5 FdOwn=%6 FdDead=%7 Fpos=%8", time, '
             'alive manL, (vehicle manL) == mgL, '
             'alive manF, (vehicle manF) == mgF, '
             'manF distance mgF, manF distance mgL, getPos manF]'), flush=True)
    time.sleep(1)
