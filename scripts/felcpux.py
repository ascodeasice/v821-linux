#!/usr/bin/env python3
"""Wake the A27 through xfel's BROM access path, then boot it to a Linux shell.

Background (why this script exists):
  The V821 is a dual-core SoC. The T-Head E907 is the boot MCU and physically has
  no Supervisor mode; the Andes A27L2 is the application core that runs Linux.
  `xfel exec` runs on the E907, so the scounteren faults, the missing S bit in
  misa, and MEDELEG=0 that were debugged early on were all symptoms of one root
  cause: the code was running on the wrong core.

  Porting BOOT0's wake-up sequence faithfully onto the E907 does not work either.
  Writing 0x49100204 faults: in FEL/FES state the E907's CPU bus cannot reach the
  CPUX_CFG block. But `xfel read32 0x49100204` does return data, so the BROM/FEL
  access path can reach it -- the core just has to come out of reset first.

  So the wake-up sequence runs on the host, poked in one word at a time through
  xfel's read32/write32. Out of reset the A27 lands in a27_stub, the stub jumps to
  OpenSBI at 0x80000000, and from there into Linux.

Every register address and field meaning comes from the Tina SDK's
  spl/board/sun300iw1p1/e907_boot/boot0_main.c and clock.c,
  plus include/arch/sun300iw1p1/clock_autogen_aon.h.
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys
import time

import serial

# ---- board constants (do not parameterise; change these and it is a different board)
A27_ENTRY = 0x83F00000      # stub load address, also written to CPUX_START_ADD; above the payload
DRAM_BASE = 0x80000000      # fw_payload load address
BAUD = 115200               # must match current-speed in the dts and bootargs

PLL_CPUX      = 0x4A010000  # CCMU_PLL_CPUX_CTRL_REG
PLL_FUNC_CFG  = 0x4A010404  # bit31 DCXO_ST: 0 = HOSC 40 MHz, 1 = 24 MHz
A27L2_CLK     = 0x4A010588  # SEL[26:24]: 0=HOSC 4=CPU_PLL
WAKUP_CTRL    = 0x4A011064  # bit8 CPUX_WUK_EN
MT_CLK        = 0x42001010
APP_CLK       = 0x4200107C
APP_RESET     = 0x42001094  # cfg / cpu reset deassert
CPUX_START    = 0x49100204
CPUX_WFI_MODE = 0x49100004

SEL_NAMES = ["HOSC", "VIDEOPLL2X", "RC1M", "RC1M0", "CPU_PLL",
             "PERI_1024M", "PERI_768M", "PERI_768M0"]


class XfelError(RuntimeError):
    pass


def parse_args():
    top = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--fw", required=True,
                   help="OpenSBI fw_payload.bin (kernel and dtb inside)")
    p.add_argument("--stub", required=True,
                   help="a27_stub.bin, where the A27 lands out of reset")
    p.add_argument("--log", default=os.path.join(top, "build", "felcpux.log"),
                   help="where to save the serial capture")
    p.add_argument("--secs", type=float, default=120.0,
                   help="capture window in seconds; ends early once the shell prompt appears")
    p.add_argument("--serial", default=os.environ.get("V821_SERIAL"),
                   help="serial device; defaults to the first /dev/ttyUSB*, then /dev/ttyACM*")
    p.add_argument("--no-pll", action="store_true",
                   help="skip PLL_CPU setup and leave the A27 mux on HOSC. This is the "
                        "slow-state control run: ~205 s to boot, so pair it with --secs=700")
    p.add_argument("--fel-wait", type=float, default=180.0,
                   help="seconds to wait for the board to enter FEL")
    return p.parse_args()


# ---- xfel wrappers ----

def xfel_raw(xfel, *a, timeout=120):
    return subprocess.run([xfel, *a], capture_output=True, text=True, timeout=timeout)


def make_xfel(xfel):
    """Return (rd32, wr32, rmw, run). run raises on a non-zero return code.

    The original discarded every subprocess return code, including the write that
    loads the stub. So a wrong path made xfel fail silently, nothing raised, and the
    program went on to release the A27 from reset to execute whatever bytes happened
    to be at 0x83f00000. The board goes completely silent, looking exactly like
    "never entered FEL". Write-like calls therefore always check the return code.
    """
    def run(*a, timeout=120):
        r = xfel_raw(xfel, *a, timeout=timeout)
        if r.returncode != 0:
            raise XfelError("xfel %s failed (rc=%d): %s%s"
                            % (" ".join(a), r.returncode, r.stdout, r.stderr))
        return r

    def rd32(addr):
        # Reads stay permissive: a probing read should not kill the whole run.
        r = xfel_raw(xfel, "read32", hex(addr), timeout=30)
        for line in reversed((r.stdout or "").splitlines()):
            line = line.strip()
            if line.startswith("0x"):
                return int(line, 16)
        return 0

    def wr32(addr, val):
        run("write32", hex(addr), hex(val))

    def rmw(addr, mask):
        v = rd32(addr)
        wr32(addr, v | mask)
        print("  rmw %#x: %#x -> %#x" % (addr, v, v | mask), flush=True)

    return rd32, wr32, rmw, run


def wait_for_fel(xfel, limit):
    print(">>> waiting for FEL (hold the FEL button and replug USB-OTG)...", flush=True)
    t0 = time.time()
    while time.time() - t0 < limit:
        try:
            if "V821" in xfel_raw(xfel, "version", timeout=8).stdout:
                print(">>> FEL is up", flush=True)
                return
        except Exception:
            pass
        time.sleep(1)
    sys.exit(">>> FEL never appeared. Check that xfel version reports V821, and USB permissions (udev rule)")


def open_serial(explicit):
    cands = [explicit] if explicit else (sorted(glob.glob("/dev/ttyUSB*"))
                                         + sorted(glob.glob("/dev/ttyACM*")))
    for path in cands:
        try:
            ser = serial.Serial(path, BAUD, timeout=0.1)
            print(">>> serial port %s" % path, flush=True)
            return ser
        except Exception as exc:
            print("    cannot open %s: %s" % (path, exc), flush=True)
    sys.exit(">>> no usable serial port. Pass --serial, or check you are in the uucp/dialout group")


def setup_pll(rd32, wr32, hosc, no_pll):
    """The A27 CPU clock. PLL_CPU frequency = HOSC * N / D.

    SDK clock.c:601-627 has two constant sets keyed on HOSC, both landing on 960 MHz:
      HOSC 40M: lock_time=3, D=2, N=48 -> 40*48/2 = 960
      HOSC 24M: lock_time=2, D=1, N=40 -> 24*40/1 = 960
    An earlier version wrote the 24M set unconditionally, which on this 40 MHz board
    means 40*40/1 = 1600 MHz -- permanently overclocked.
    """
    if no_pll:
        # Only move the mux back to HOSC and leave the PLL alone, so the control run
        # differs from the normal one by exactly that mux setting.
        wr32(A27L2_CLK, 0x80000000)
        print("  --no-pll: A27 mux back on HOSC (%d MHz)" % hosc, flush=True)
        return

    want_n, want_d, want_lt = (48, 2, 3) if hosc == 40 else (40, 1, 2)
    v = rd32(PLL_CPUX)
    n = ((v >> 8) & 0xFF) + 1
    d = ((v >> 2) & 3) + 1
    locked = (v >> 31) & 1 and (v >> 28) & 1
    if locked and n == want_n and d == want_d:
        print("  PLL_CPU is already %d*%d/%d = %d MHz (set up by xfel ddr, leaving it)"
              % (hosc, want_n, want_d, hosc * want_n // want_d), flush=True)
    else:
        # Replay the SDK's set_pll_general order in full.
        wr32(PLL_CPUX, rd32(PLL_CPUX) | (1 << 30))                              # LDO on
        wr32(PLL_CPUX, rd32(PLL_CPUX) & ~((1 << 31) | (1 << 27) | (1 << 29)))   # clear EN/gate/lock_en
        time.sleep(0.002)
        wr32(PLL_CPUX, (rd32(PLL_CPUX) & ~0x07000000) | (want_lt << 24))        # lock_time
        wr32(PLL_CPUX, (rd32(PLL_CPUX) & ~0x0000000C) | ((want_d - 1) << 2))    # input_div
        wr32(PLL_CPUX, (rd32(PLL_CPUX) & ~0x0000FF00) | ((want_n - 1) << 8))    # N
        wr32(PLL_CPUX, rd32(PLL_CPUX) | (1 << 31))                              # PLL_EN
        wr32(PLL_CPUX, rd32(PLL_CPUX) | (1 << 29))                              # LOCK_EN
        time.sleep(0.003)                                                       # wait for lock (bit28)
        wr32(PLL_CPUX, rd32(PLL_CPUX) | (1 << 27))                              # OUTPUT_GATE
        print("  PLL_CPU set to %d*%d/%d = %d MHz"
              % (hosc, want_n, want_d, hosc * want_n // want_d), flush=True)
    wr32(A27L2_CLK, 0x84000000)   # sel=CPU_PLL(4<<24) | en(1<<31), div=0


def main():
    args = parse_args()

    xfel = os.environ.get("XFEL", "xfel")
    if not shutil.which(xfel):
        sys.exit("xfel not found. Install it and put it on PATH: https://github.com/xboot/xfel")

    # Check the files exist and are non-empty first. These two exits replace the
    # original's silent-load-failure behaviour.
    for label, path in (("fw_payload", args.fw), ("a27_stub", args.stub)):
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            sys.exit("%s is missing or empty: %s (run make first)" % (label, path))
    print(">>> fw_payload: %s (%d bytes)" % (args.fw, os.path.getsize(args.fw)), flush=True)
    print(">>> a27_stub:   %s (%d bytes)" % (args.stub, os.path.getsize(args.stub)), flush=True)

    wait_for_fel(xfel, args.fel_wait)
    rd32, wr32, rmw, run = make_xfel(xfel)

    # Clock state before boot. Mainline has no CCU driver, so clk_summary is empty and
    # these readbacks are the only hard evidence of how fast the CPU actually runs.
    fn = rd32(PLL_FUNC_CFG)
    hosc = 24 if (fn >> 31) & 1 else 40
    a27 = rd32(A27L2_CLK)
    pll = rd32(PLL_CPUX)
    print("  HOSC=%d MHz (PLL_FUNC_CFG=%#x DCXO_ST=%d)" % (hosc, fn, (fn >> 31) & 1), flush=True)
    print("  before wake-up: A27_CLK=%#x SEL=%s  PLL_CPU=%#x (EN=%d N=%d D=%d)"
          % (a27, SEL_NAMES[(a27 >> 24) & 7], pll, (pll >> 31) & 1,
             ((pll >> 8) & 0xFF) + 1, ((pll >> 2) & 3) + 1), flush=True)

    os.makedirs(os.path.dirname(os.path.abspath(args.log)), exist_ok=True)
    ser = open_serial(args.serial)
    logf = open(args.log, "wb")

    def read_serial():
        try:
            d = ser.read(8192)
        except Exception:
            return b""
        if d:
            sys.stdout.buffer.write(d)
            sys.stdout.flush()
            logf.write(d)
            logf.flush()
        return d

    # Push the A27 back into reset before touching DRAM. On a rerun it is still
    # executing the previous round's code, `xfel ddr` reinitialises the DRAM
    # controller underneath it, and the 10 MB payload write collides with its
    # instruction fetches. That is the intermittent soft reboot behind "the stub
    # printed #YWV and then OpenSBI said nothing".
    print("  pushing the A27 back into reset (%#x=%#x)" % (APP_RESET, rd32(APP_RESET)), flush=True)
    wr32(APP_RESET, rd32(APP_RESET) & ~0x1C000000)

    run("ddr", timeout=180)
    run("write", hex(DRAM_BASE), args.fw, timeout=600)
    run("write", hex(A27_ENTRY), args.stub, timeout=60)

    print(">>> starting the A27 wake-up (BOOT0 sequence)...", flush=True)
    rmw(WAKUP_CTRL, 0x100)                 # CPUX_WUK_EN
    setup_pll(rd32, wr32, hosc, args.no_pll)

    pll = rd32(PLL_CPUX)
    a27 = rd32(A27L2_CLK)
    n = ((pll >> 8) & 0xFF) + 1
    d = ((pll >> 2) & 3) + 1
    sel = (a27 >> 24) & 7
    freq = hosc if sel == 0 else (hosc * n // d if sel == 4 else 0)
    print("  PLL_CPU=%#x (EN=%d lock=%d N=%d D=%d gives %d MHz)  A27_CLK=%#x (SEL=%s)"
          % (pll, (pll >> 31) & 1, (pll >> 28) & 1, n, d, hosc * n // d, a27, SEL_NAMES[sel]),
          flush=True)
    print("  ==> A27 CPU clock = %d MHz" % freq, flush=True)

    wr32(MT_CLK, 0x80000000)               # CLK_EN
    v = rd32(APP_CLK)
    wr32(APP_CLK, (v & ~0x300) | 0x1C0)
    rmw(APP_RESET, 0x18000000)             # msgbox / cfg reset deassert

    wr32(CPUX_START, A27_ENTRY)
    back = rd32(CPUX_START)
    print("  START_ADD readback: %#x (want %#x)" % (back, A27_ENTRY), flush=True)
    if back != A27_ENTRY:
        # Before the cfg reset is deasserted this write is ignored. If the readback
        # does not match, do not release the core.
        sys.exit("  START_ADD did not stick, stopping instead of releasing the A27")
    wr32(CPUX_WFI_MODE, 0)
    rmw(APP_RESET, 0x04000000)             # cpu reset deassert, the A27 starts running

    print(">>> A27 released from reset, capturing for %d seconds...\n" % args.secs, flush=True)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < args.secs:
        buf += read_serial()
        time.sleep(0.02)
        if b"/ #" in buf:
            print("\n>>> SHELL on A27!\n", flush=True)
            break
    logf.close()
    print(">>> done, log at %s" % args.log, flush=True)


if __name__ == "__main__":
    main()
