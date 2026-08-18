#!/bin/busybox sh
# mainline/init/init.sh -- V821 RV32 mainline /init (Stage B).
# We boot the A27 (S-mode) via our own OpenSBI over FEL, bypassing the vendor
# chain, so the old ~62s deadman is not armed -- the aondump scan + watchdog
# feeder from the deadman hunt are removed. Just mount the pseudo-fs, populate
# /dev, and hand off to an interactive shell with a controlling tty.

/bin/busybox mount -t proc     proc     /proc 2>/dev/null
/bin/busybox mount -t sysfs    sysfs    /sys  2>/dev/null
/bin/busybox mount -t devtmpfs devtmpfs /dev  2>/dev/null
/bin/busybox mount -t debugfs  debugfs  /sys/kernel/debug 2>/dev/null
/bin/busybox --install -s /bin

echo
echo ">>> V821 rv32 mainline on A27 (S-mode, own OpenSBI via FEL)."
# timer-calibration probe: sleep 5 between two uptime reads. Off-line we compare
# the kernel uptime delta (~5) against the captured wall-clock to check that
# timebase-frequency (DTB 40 MHz) matches the real PLMT mtime rate.
echo "TMR_A=$(/bin/busybox cut -d' ' -f1 /proc/uptime)"
/bin/busybox sleep 5
echo "TMR_B=$(/bin/busybox cut -d' ' -f1 /proc/uptime)"

# CPU-clock probes -- see claude-report.md §30.
# (1) absolute: the A27 clock mux setting. Absolute frequency is always derived from
# the registers felcpux prints (HOSC 40 MHz x N/D) -- no register on this board
# reports the rate the A27 is actually running at.
echo "CLK_REG_NOW=$(/bin/busybox devmem 0x4A010588)"
# (2) relative: a fixed shell loop timed against the (already-verified) timer.
echo "CPU_A=$(/bin/busybox cut -d' ' -f1 /proc/uptime)"
i=0; while [ $i -lt 2000 ]; do i=$((i+1)); done
echo "CPU_B=$(/bin/busybox cut -d' ' -f1 /proc/uptime) (2000-iteration shell loop)"

# clk_summary. Expect it to be empty apart from the header: the minimal DT has no
# clock provider (no CCU node), so nothing registers with CONFIG_COMMON_CLK. Dumped
# anyway so the report can cite the emptiness instead of asserting it.
echo ">>> clk_summary:"
/bin/busybox cat /sys/kernel/debug/clk/clk_summary 2>&1

echo ">>> interactive shell (busybox):"
echo

exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
