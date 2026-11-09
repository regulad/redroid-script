"""Boots an arm64 guest under QEMU TCG and times it.

    python3 tcg-bench.py <qemu command...>

Marks when the kernel starts, when it hands over to userspace (rdinit=/bin/sh,
the initramfs's busybox), and when a CPU-bound shell loop typed into that
shell finishes. Stops after the loop, or after 15 minutes.
"""
import os, re, select, subprocess, sys, time

t0 = time.monotonic()
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
buf, marks, sent = b"", {}, False

def mark(name):
    if name not in marks:
        marks[name] = time.monotonic() - t0
        print(f"[{marks[name]:7.1f}s] {name}", flush=True)

loop = b'i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done; echo LOOP$((1+1))DONE\n'
while time.monotonic() - t0 < 900:
    ready, _, _ = select.select([p.stdout], [], [], 1)
    if not ready:
        continue
    chunk = os.read(p.stdout.fileno(), 65536)
    if not chunk:
        break
    buf += chunk
    if b"Linux version" in buf:
        mark("kernel started")
    if b"Run /bin/sh as init process" in buf:
        mark("userspace started")
        if not sent:
            time.sleep(2)
            p.stdin.write(loop); p.stdin.flush(); sent = True
            mark("loop sent")
    if b"LOOP2DONE" in buf:
        mark("loop done")
        break
    if re.search(rb"Kernel panic", buf):
        mark("kernel panic")
        break
p.kill()
print(buf.decode(errors="replace")[-1500:])
if "loop done" in marks and "loop sent" in marks:
    print(f"RESULT kernel_to_userspace={marks['userspace started'] - marks['kernel started']:.1f}s "
          f"loop={marks['loop done'] - marks['loop sent']:.1f}s total={marks['loop done']:.1f}s")
else:
    print(f"RESULT incomplete: {marks}")
