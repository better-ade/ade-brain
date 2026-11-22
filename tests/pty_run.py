#!/usr/bin/env python3
"""pty_run.py [-i ANSWER]... -- CMD [ARG...]: run CMD with a pseudo-terminal as its stdin, stdout and stderr.

Each -i ANSWER is typed as one line, ahead of time (the terminal queues them, as a person typing ahead would), and an
end of input (Ctrl-D) follows the last one, so a question the answers do not cover ends instead of waiting.
Prints what the terminal showed (carriage returns removed) and exits with CMD's status; a CMD still running after
PTY_RUN_TIMEOUT seconds (default 60) is killed and the exit status is 124. Python's standard library only, so the
same script runs under macOS and Linux (bash 3.2 and bash 5 alike).
"""
import os, select, signal, subprocess, sys, termios, time

args = sys.argv[1:]
answers = []
while args and args[0] == "-i":
    answers.append(args[1])
    args = args[2:]
if not args or args[0] != "--" or len(args) < 2:
    sys.stderr.write(__doc__)
    sys.exit(2)
cmd = args[1:]

master, slave = os.openpty()
eof = termios.tcgetattr(slave)[6][termios.VEOF]
eof = eof if isinstance(eof, bytes) else bytes([eof])
proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
os.write(master, b"".join(a.encode() + b"\n" for a in answers) + eof)

out = b""
deadline = time.time() + float(os.environ.get("PTY_RUN_TIMEOUT", "60"))
while True:
    left = deadline - time.time()
    if left <= 0:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        sys.stdout.write(out.decode(errors="replace").replace("\r", ""))
        sys.exit(124)
    r, _, _ = select.select([master], [], [], min(left, 0.2))
    if r:
        try:
            chunk = os.read(master, 4096)
        except OSError:  # Linux: EIO once every slave end is closed
            chunk = b""
        if chunk:
            out += chunk
            continue
        break
    if proc.poll() is not None:
        # macOS can keep the master readable-silent after the child exits: drain what is left, then stop
        try:
            while select.select([master], [], [], 0.1)[0]:
                chunk = os.read(master, 4096)
                if not chunk:
                    break
                out += chunk
        except OSError:
            pass
        break
rc = proc.wait()
sys.stdout.write(out.decode(errors="replace").replace("\r", ""))
sys.exit(rc if rc >= 0 else 128 - rc)
