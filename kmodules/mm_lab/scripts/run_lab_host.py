#!/usr/bin/env python3
"""Host-side harness: boot arm64_mm BusyBox VM and run mm reclaim ftrace labs."""

import os
import pty
import re
import select
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
LOG = os.path.join(ROOT, "kmodules/mm_lab/lab_run.log")
# BusyBox ash prompt variants + "press Enter" askfirst console
SHELL_READY_RE = re.compile(
    rb"(?:/# |/ # |~ # |Please press Enter to activate this console)"
)


def spawn_qemu():
    cmd = ["./run_busybox.sh", "arm64_mm"]
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvp(cmd[0], cmd)
    return pid, fd


def _norm(data: bytes) -> bytes:
    """Normalize serial CRLF / bare CR to LF for reliable matching."""
    return data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def read_until(fd, pattern, timeout=120, logf=None):
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 1.0)
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if logf:
            logf.write(chunk.decode("utf-8", "replace"))
            logf.flush()
        norm = _norm(buf)
        if isinstance(pattern, bytes):
            if _norm(pattern) in norm:
                return buf
        else:
            if pattern.search(norm):
                return buf
    raise TimeoutError(f"timeout waiting for {pattern!r}, last={buf[-400:]!r}")


def send(fd, cmd, logf=None):
    data = (cmd + "\n").encode()
    if logf:
        logf.write(f"\n>>> {cmd}\n")
        logf.flush()
    os.write(fd, data)


def wait_shell(fd, logf=None):
    """Wait for boot, poke askfirst console if needed."""
    for attempt in range(3):
        try:
            out = read_until(fd, SHELL_READY_RE, timeout=60, logf=logf)
            if b"Please press Enter" in out:
                send(fd, "", logf)
                continue
            # Disable local echo so our end-marker is not matched from the
            # typed command line itself (pty echo was racing completions).
            send(fd, "stty -echo 2>/dev/null; echo __SHELL_OK__", logf)
            read_until(fd, b"__SHELL_OK__", timeout=20, logf=logf)
            return
        except TimeoutError:
            send(fd, "", logf)
    raise TimeoutError("could not get a usable shell")


def run_cmd(fd, cmd, timeout=180, logf=None):
    # Print marker on its own line via printf; with stty -echo the marker
    # string only appears when the command actually finishes.
    marker = f"DONE{int(time.time() * 1000)}"
    send(fd, f"{cmd}; printf '\\n%s\\n' {marker}", logf)
    out = read_until(fd, f"\n{marker}\n".encode(), timeout=timeout, logf=logf)
    return out.decode("utf-8", "replace")


def main():
    steps = [
        ("setup", "sh /mnt/mm_lab/scripts/mm_setup.sh", 300),
        ("watermark", "sh /mnt/mm_lab/scripts/show_watermark.sh", 60),
        ("exp1",
         "sh /mnt/mm_lab/scripts/drop_caches.sh; "
         "sh /mnt/mm_lab/scripts/trace_reclaim.sh "
         "'cat /data/bigfile > /dev/null' /tmp/exp1.trace",
         300),
        ("exp2",
         "sh /mnt/mm_lab/scripts/fill_cache.sh; "
         "sh /mnt/mm_lab/scripts/trace_reclaim.sh "
         "'/mnt/mm_lab/memhog 150 3 16' /tmp/exp2.trace",
         360),
        ("exp3",
         "sh /mnt/mm_lab/scripts/fill_cache.sh; "
         "sh /mnt/mm_lab/scripts/trace_stack.sh mm_vmscan_direct_reclaim_begin "
         "'/mnt/mm_lab/memhog 160 1 16 >/dev/null' /tmp/exp3.stack",
         360),
        ("exp4",
         "sh /mnt/mm_lab/scripts/fill_cache.sh; "
         "sh /mnt/mm_lab/scripts/trace_func.sh "
         "'/mnt/mm_lab/memhog 160 1 16 >/dev/null' /tmp/exp4.func",
         420),
        ("copy",
         "cp /tmp/exp1.trace /tmp/exp2.trace /tmp/exp3.stack /tmp/exp4.func "
         "/mnt/mm_lab/; ls -l /mnt/mm_lab/exp1.trace /mnt/mm_lab/exp2.trace "
         "/mnt/mm_lab/exp3.stack /mnt/mm_lab/exp4.func",
         60),
    ]

    only = sys.argv[1:] if len(sys.argv) > 1 else None
    if only:
        # always keep setup first when filtering
        names = set(only)
        steps = [s for s in steps if s[0] in names or s[0] == "setup"]
        # de-dup setup if user asked for it
        seen = set()
        uniq = []
        for s in steps:
            if s[0] in seen:
                continue
            seen.add(s[0])
            uniq.append(s)
        steps = uniq

    with open(LOG, "w") as logf:
        print(f"[host] starting qemu, log={LOG}", flush=True)
        pid, fd = spawn_qemu()
        try:
            print("[host] waiting for shell...", flush=True)
            wait_shell(fd, logf=logf)
            print("[host] shell ready", flush=True)

            run_cmd(fd, "ls /mnt/mm_lab/scripts", timeout=30, logf=logf)

            for name, cmd, to in steps:
                print(f"[host] === {name} ===", flush=True)
                logf.write(f"\n\n===== STEP {name} =====\n")
                logf.flush()
                try:
                    run_cmd(fd, cmd, timeout=to, logf=logf)
                    print(f"[host] {name} OK", flush=True)
                except TimeoutError as e:
                    print(f"[host] {name} TIMEOUT: {e}", flush=True)
                    break

            print("[host] poweroff", flush=True)
            send(fd, "poweroff -f", logf)
            time.sleep(4)
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass

    print(f"[host] done, see {LOG}")


if __name__ == "__main__":
    main()

