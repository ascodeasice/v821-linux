#!/usr/bin/env python3
"""透過 xfel 的 BROM 存取路徑喚醒 A27，然後開機到 Linux shell。

背景（這支存在的理由）：
  V821 是雙核 SoC。T-Head E907 是 boot MCU，物理上沒有 Supervisor mode；
  Andes A27L2 才是跑 Linux 的應用核。`xfel exec` 執行的是 E907，所以早期一路
  在 debug 的 scounteren fault、misa 沒有 S、MEDELEG=0 全都是同一個根因的症狀：
  程式跑在錯的核上（claude-report.md §18.1）。

  把 BOOT0 的喚醒序列忠實搬進 E907 執行也不行——寫 0x49100204 會 fault，
  E907 在 FEL/FES 狀態下的 CPU bus 到不了 CPUX_CFG block。但 `xfel read32
  0x49100204` 讀得到，表示 BROM/FEL 的存取路徑到得了，只差先解 reset。

  所以喚醒序列跑在 host 上，透過 xfel 的 read32/write32 一格一格寫進去。
  A27 出 reset 後落在 a27_stub，stub 跳到 0x80000000 的 OpenSBI，再進 Linux。

所有暫存器位址與欄位語意出自 Tina SDK 的
  spl/board/sun300iw1p1/e907_boot/boot0_main.c 與 clock.c，
  以及 include/arch/sun300iw1p1/clock_autogen_aon.h。
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys
import time

import serial

# ---- 板子常數（不要參數化，改這些就不是這塊板子了）----
A27_ENTRY = 0x83F00000      # stub 載入位址，也寫進 CPUX_START_ADD。在 payload 之上
DRAM_BASE = 0x80000000      # fw_payload 載入位址
BAUD = 115200               # 要跟 dts 的 current-speed 與 bootargs 一致

PLL_CPUX      = 0x4A010000  # CCMU_PLL_CPUX_CTRL_REG
PLL_FUNC_CFG  = 0x4A010404  # bit31 DCXO_ST：0 = HOSC 40MHz，1 = 24MHz
A27L2_CLK     = 0x4A010588  # SEL[26:24]：0=HOSC 4=CPU_PLL
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
    top = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--fw", required=True,
                   help="OpenSBI fw_payload.bin（內含 kernel 與 dtb）")
    p.add_argument("--stub", required=True,
                   help="a27_stub.bin，A27 出 reset 後的落地點")
    p.add_argument("--log", default=os.path.join(top, "build", "felcpux.log"),
                   help="序列埠擷取的存檔位置")
    p.add_argument("--secs", type=float, default=120.0,
                   help="擷取視窗秒數。抓到 shell prompt 會提早結束")
    p.add_argument("--serial", default=os.environ.get("V821_SERIAL"),
                   help="序列埠裝置。預設自動找 /dev/ttyUSB* 再找 /dev/ttyACM*")
    p.add_argument("--no-pll", action="store_true",
                   help="不設 PLL_CPU，把 A27 的 mux 留在 HOSC。這是慢速態的對照組，"
                        "開機要 ~205 秒，記得配 --secs=700")
    p.add_argument("--fel-wait", type=float, default=180.0,
                   help="等板子進 FEL 的秒數")
    return p.parse_args()


# ---- xfel 包裝 ----

def xfel_raw(xfel, *a, timeout=120):
    return subprocess.run([xfel, *a], capture_output=True, text=True, timeout=timeout)


def make_xfel(xfel):
    """回傳 (rd32, wr32, rmw, run)。run 對非零 return code 會 raise。

    原版把每個 subprocess 的 return code 都丟掉，包含載入 stub 的那次 write。
    結果是路徑打錯時 xfel 靜靜失敗、沒有任何東西 raise，程式照樣把 A27 放出
    reset，讓它去跑 0x83f00000 上剛好是什麼的位元組。板子全靜音，長得跟
    「沒進 FEL」一模一樣。所以寫入類的呼叫一律檢查 return code。
    """
    def run(*a, timeout=120):
        r = xfel_raw(xfel, *a, timeout=timeout)
        if r.returncode != 0:
            raise XfelError("xfel %s 失敗（rc=%d）：%s%s"
                            % (" ".join(a), r.returncode, r.stdout, r.stderr))
        return r

    def rd32(addr):
        # 讀取保持寬容：探測用的讀不該讓整支掛掉
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
    print(">>> 等板子進 FEL（按住 FEL 鈕重插 USB-OTG）...", flush=True)
    t0 = time.time()
    while time.time() - t0 < limit:
        try:
            if "V821" in xfel_raw(xfel, "version", timeout=8).stdout:
                print(">>> FEL 上線", flush=True)
                return
        except Exception:
            pass
        time.sleep(1)
    sys.exit(">>> 等不到 FEL。確認 xfel version 看得到 V821，以及 USB 權限（udev rule）")


def open_serial(explicit):
    cands = [explicit] if explicit else (sorted(glob.glob("/dev/ttyUSB*"))
                                         + sorted(glob.glob("/dev/ttyACM*")))
    for path in cands:
        try:
            ser = serial.Serial(path, BAUD, timeout=0.1)
            print(">>> 序列埠 %s" % path, flush=True)
            return ser
        except Exception as exc:
            print("    %s 打不開：%s" % (path, exc), flush=True)
    sys.exit(">>> 找不到可用的序列埠。用 --serial 指定，或確認你在 uucp/dialout 群組")


def setup_pll(rd32, wr32, hosc, no_pll):
    """A27 的 CPU 時脈。PLL_CPU 頻率 = HOSC * N / D。

    SDK clock.c:601-627 依 HOSC 分兩組常數，兩組都指向 960 MHz：
      HOSC 40M：lock_time=3、D=2、N=48 -> 40*48/2 = 960
      HOSC 24M：lock_time=2、D=1、N=40 -> 24*40/1 = 960
    舊版無條件寫 24M 那組，在這塊 40 MHz 的板子上等於 40*40/1 = 1600 MHz，
    也就是一直在超頻（claude-report.md §30.10）。
    """
    if no_pll:
        # 只把 mux 切回 HOSC，PLL 不動，對照組跟正常組只差 mux 這一項
        wr32(A27L2_CLK, 0x80000000)
        print("  --no-pll：A27 mux 切回 HOSC（%d MHz）" % hosc, flush=True)
        return

    want_n, want_d, want_lt = (48, 2, 3) if hosc == 40 else (40, 1, 2)
    v = rd32(PLL_CPUX)
    n = ((v >> 8) & 0xFF) + 1
    d = ((v >> 2) & 3) + 1
    locked = (v >> 31) & 1 and (v >> 28) & 1
    if locked and n == want_n and d == want_d:
        print("  PLL_CPU 已經是 %d*%d/%d = %d MHz（xfel ddr 設好的，不動它）"
              % (hosc, want_n, want_d, hosc * want_n // want_d), flush=True)
    else:
        # 完整重跑 SDK set_pll_general 的順序
        wr32(PLL_CPUX, rd32(PLL_CPUX) | (1 << 30))                              # LDO on
        wr32(PLL_CPUX, rd32(PLL_CPUX) & ~((1 << 31) | (1 << 27) | (1 << 29)))   # 清 EN/gate/lock_en
        time.sleep(0.002)
        wr32(PLL_CPUX, (rd32(PLL_CPUX) & ~0x07000000) | (want_lt << 24))        # lock_time
        wr32(PLL_CPUX, (rd32(PLL_CPUX) & ~0x0000000C) | ((want_d - 1) << 2))    # input_div
        wr32(PLL_CPUX, (rd32(PLL_CPUX) & ~0x0000FF00) | ((want_n - 1) << 8))    # N
        wr32(PLL_CPUX, rd32(PLL_CPUX) | (1 << 31))                              # PLL_EN
        wr32(PLL_CPUX, rd32(PLL_CPUX) | (1 << 29))                              # LOCK_EN
        time.sleep(0.003)                                                       # 等 lock（bit28）
        wr32(PLL_CPUX, rd32(PLL_CPUX) | (1 << 27))                              # OUTPUT_GATE
        print("  PLL_CPU 重設為 %d*%d/%d = %d MHz"
              % (hosc, want_n, want_d, hosc * want_n // want_d), flush=True)
    wr32(A27L2_CLK, 0x84000000)   # sel=CPU_PLL(4<<24) | en(1<<31)，div=0


def main():
    args = parse_args()

    xfel = os.environ.get("XFEL", "xfel")
    if not shutil.which(xfel):
        sys.exit("找不到 xfel。裝好並放進 PATH：https://github.com/xboot/xfel")

    # 先確認檔案在、而且不是空的。這兩個 exit 取代了原版「靜默載入失敗」的行為
    for label, path in (("fw_payload", args.fw), ("a27_stub", args.stub)):
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            sys.exit("%s 不存在或是空檔：%s（先跑 make）" % (label, path))
    print(">>> fw_payload: %s（%d bytes）" % (args.fw, os.path.getsize(args.fw)), flush=True)
    print(">>> a27_stub:   %s（%d bytes）" % (args.stub, os.path.getsize(args.stub)), flush=True)

    wait_for_fel(xfel, args.fel_wait)
    rd32, wr32, rmw, run = make_xfel(xfel)

    # 開機前的時脈狀態。mainline 沒有 CCU driver，clk_summary 是空的，
    # 所以這幾行 readback 就是「CPU 到底跑多快」唯一的硬證據（claude-report.md §24）。
    fn = rd32(PLL_FUNC_CFG)
    hosc = 24 if (fn >> 31) & 1 else 40
    a27 = rd32(A27L2_CLK)
    pll = rd32(PLL_CPUX)
    print("  HOSC=%d MHz（PLL_FUNC_CFG=%#x DCXO_ST=%d）" % (hosc, fn, (fn >> 31) & 1), flush=True)
    print("  喚醒前：A27_CLK=%#x SEL=%s  PLL_CPU=%#x（EN=%d N=%d D=%d）"
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

    # 碰 DRAM 之前先把 A27 押回 reset。重跑時它還在執行上一輪的東西，
    # `xfel ddr` 會在它腳下重新初始化 DRAM 控制器，10 MB 的 payload 寫入
    # 又跟它的 fetch 相撞——這就是「stub 印了 #YWV 然後 OpenSBI 沒聲音」的
    # 那個時有時無的軟重啟（claude-report.md §26.3）。
    print("  押回 A27 reset（%#x=%#x）" % (APP_RESET, rd32(APP_RESET)), flush=True)
    wr32(APP_RESET, rd32(APP_RESET) & ~0x1C000000)

    run("ddr", timeout=180)
    run("write", hex(DRAM_BASE), args.fw, timeout=600)
    run("write", hex(A27_ENTRY), args.stub, timeout=60)

    print(">>> 開始喚醒 A27（BOOT0 序列）...", flush=True)
    rmw(WAKUP_CTRL, 0x100)                 # CPUX_WUK_EN
    setup_pll(rd32, wr32, hosc, args.no_pll)

    pll = rd32(PLL_CPUX)
    a27 = rd32(A27L2_CLK)
    n = ((pll >> 8) & 0xFF) + 1
    d = ((pll >> 2) & 3) + 1
    sel = (a27 >> 24) & 7
    freq = hosc if sel == 0 else (hosc * n // d if sel == 4 else 0)
    print("  PLL_CPU=%#x（EN=%d lock=%d N=%d D=%d 得 %d MHz）  A27_CLK=%#x（SEL=%s）"
          % (pll, (pll >> 31) & 1, (pll >> 28) & 1, n, d, hosc * n // d, a27, SEL_NAMES[sel]),
          flush=True)
    print("  ==> A27 CPU clock = %d MHz" % freq, flush=True)

    wr32(MT_CLK, 0x80000000)               # CLK_EN
    v = rd32(APP_CLK)
    wr32(APP_CLK, (v & ~0x300) | 0x1C0)
    rmw(APP_RESET, 0x18000000)             # msgbox / cfg reset deassert

    wr32(CPUX_START, A27_ENTRY)
    back = rd32(CPUX_START)
    print("  START_ADD 回讀：%#x（要 %#x）" % (back, A27_ENTRY), flush=True)
    if back != A27_ENTRY:
        # 解 cfg reset 之前這個寫入會被忽略。回讀不符就別放核出來
        sys.exit("  START_ADD 沒寫進去，停在這裡不放 A27 出 reset")
    wr32(CPUX_WFI_MODE, 0)
    rmw(APP_RESET, 0x04000000)             # cpu reset deassert，A27 開始跑

    print(">>> A27 已放出 reset，擷取 %d 秒...\n" % args.secs, flush=True)
    buf = b""
    t0 = time.time()
    while time.time() - t0 < args.secs:
        buf += read_serial()
        time.sleep(0.02)
        if b"/ #" in buf:
            print("\n>>> SHELL on A27!\n", flush=True)
            break
    logf.close()
    print(">>> 結束，log 在 %s" % args.log, flush=True)


if __name__ == "__main__":
    main()
