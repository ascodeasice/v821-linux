# RESULTS — 每個宣稱對應一條可以跑的指令

報告裡講的每個數字，這裡都給出重現它的指令和該看到的證據行。分成兩組：
**不用板子的**（任何人 clone 下來就能跑）與**要板子的**（需要一塊 AvaotaF1 進 FEL）。

跑之前先 `./build.sh`。

---

## 不用板子

### R1 — 兩個人編出同一顆 firmware

```sh
git clone <repo> /tmp/a && cd /tmp/a && ./build.sh
git clone <repo> /tmp/b && cd /tmp/b && ./build.sh
sha256sum /tmp/{a,b}/build/opensbi/build/platform/generic/firmware/fw_payload.bin
```

兩行 sha256 相同。

kernel 預設不是可重現建置，變動來源有兩個：banner 裡的建置時間戳，以及 initramfs
cpio 標頭裡的檔案 mtime（`git checkout` 出來的時間每個人都不同）。`Makefile` 把
`KBUILD_BUILD_TIMESTAMP` 釘死，這一個變數兩處都管——banner 直接用它，cpio 是
`usr/Makefile:67` 把它當 `gen_initramfs.sh` 的 `-d` 傳下去。要看真實建置時間就
`make KBUILD_BUILD_TIMESTAMP="$(date)"`。

### R2 — fw_payload 裡面包的是對的 device tree

```sh
make verify
```

`make` 綠燈不等於包對。dtb 曾經因為 `dtc` 沒重跑而包了舊的一顆進去，板子照常
開機、只是跑錯設定，完全沒有徵兆。這條把 FDT 從 firmware blob 裡挖回來看：

```
FDT 位於 0x24020，totalsize=18176
riscv,isa              Error at 'riscv,isa': FDT_ERR_NOTFOUND
riscv,isa-base         rv32i
riscv,isa-extensions   i m a c zicsr zifencei zicntr zihpm
mmu-type               riscv,sv32
timebase-frequency     40000000
bootargs               earlycon=uart8250,mmio32,0x42500000 console=ttyS0,115200 loglevel=8
uart0-status           okay
uart0-clock            192000000
plmt                   andestech,plmt0
```

`riscv,isa` 顯示 `FDT_ERR_NOTFOUND` 是**預期的**，那正是這份 dts 的設計：只用
`riscv,isa-base` / `riscv,isa-extensions` 這組新介面。它若突然出現，表示有人把
legacy 屬性加回去了。

### R3 — 新 toolchain 沒有發出 A27 沒有的指令

```sh
make check
```

```
vmlinux 沒有 Zacas/Zabha 指令              ok
```

`arch/riscv/Makefile:83,86` 看的是 `CONFIG_TOOLCHAIN_HAS_ZACAS/ZABHA`（toolchain
有沒有能力），不是 `CONFIG_RISCV_ISA_ZACAS`（我們有沒有要用）。binutils 2.38 以上
會讓 `_zacas_zabha` 自動進 `-march`，gcc 就被授權發 `amocas.*` 與 byte/halfword 的
`amo*.b/.h`。A27 兩個都沒有，執行到就是沒有 handler 的 illegal instruction。

手動版：

```sh
riscv64-linux-gnu-objdump -d build/kernel/vmlinux \
  | grep -E '\bamocas\.|\bamo(add|and|or|swap|xor|max|min)u?\.(b|h)\b'
```

無輸出才算過。

### R4 — stub 沒有被 PIE 或 build-id 汙染

```sh
make check
```

```
a27_stub 與 golden 相同                     ok（134 bytes）
```

發行版 gcc 多半是 `--enable-default-pie`。kernel 和 OpenSBI 都自己關掉了，stub 的
build line 原本沒有。`-Ttext=` 配 default PIE 會產生沒人套用的 `R_RISCV_RELATIVE`；
build-id note 則會拿到 `0x83f00000` 以下的位址，`objcopy -O binary` 把 note 排在
code 前面，A27 出 reset 第一件事就是執行 note header。兩種都是板子全靜音、沒有
任何訊息，跟「沒進 FEL」長得一模一樣。

134 bytes 的 golden binary 直接 check 在 repo 裡，`cmp` 不過就 build 失敗。這一項
同時抓 PIE、build-id 與 codegen 漂移，成本是零。

### R5 — kernel config 的精簡是可檢查的

```sh
make config-diff
cat config-diff.txt
```

`config/v821_rv32_defconfig` 是 112 行，對應的 `.config` 是 1991 行。`config/config-diff.txt` 是
兩份 `savedefconfig` 輸出的 diff，也就是相對於 Kconfig 預設值的最小表述，所以看到
的就是真正做過的決定：21 個主動關掉的開關、23 項設定。

直接對 `.config` 跑 `scripts/diffconfig` 會得到 4101 行，其中 3999 行是關掉
NET / IIO / DRM 等上層開關之後的連鎖移除，沒有閱讀價值。

round-trip 可以自己驗：

```sh
diff <(grep '^CONFIG_\|^# CONFIG_' build/kernel/.config | sort) \
     <(cd build/linux && ./scripts/config --file ../kernel/.config --state INITRAMFS_SOURCE >/dev/null; \
       grep '^CONFIG_\|^# CONFIG_' ../kernel/.config | sort)
```

### R6 — patch 仍然對得上釘住的 commit

```sh
make patch-check
```

```
  ok  linux-01-alternative-workaround.patch
  ok  linux-02-early-uart-markers.patch
  ok  opensbi-01-v821-a27-port.patch
```

用 `git apply --check -R` 反向套用來驗，比正向套用更嚴格：它同時證明 patch 描述的
改動確實在樹上、而且沒有被別的東西蓋掉。

### R7 — device tree 的最小化幅度

```sh
grep -c '' v821-min.dts                                    # 162 行（其中 85 行是註解）
grep -v '^\s*\*\|^\s*/\*\|^\s*//\|^\s*$' v821-min.dts | grep -c ''   # 77 行實體
dtc -I dtb -O dts build/v821-min.dtb | grep -c '{'         # 13（12 個節點加 root）
```

12 個節點是：`chosen`、`aliases`、`cpus`、`cpu@0`、`cpu@0/interrupt-controller`、
`memory@80000000`、`reserved-memory`、`opensbi@80fc0000`、`soc`、`serial@42500000`、
`interrupt-controller@48000000`（PLIC）、`timer@48400000`（PLMT）。真正描述硬體的
只有後面五個，其餘是 kernel 早期路徑要讀的 metadata。

vendor 的 `passed.dts` 是 2472 行、約 229 個節點，光 `soc@2002000` 就佔 1800 行。
砍掉的 95% 就是整個設計的核心動作，每個節點留下的理由寫在 dts 的註解裡。

---

## 要板子（一次 power-cycle 可以全部驗完）

按住 FEL 鈕重插 USB-OTG，確認 `xfel version` 看得到 V821，然後：

```sh
make boot
```

log 會同時寫到 `build/felcpux.log`。已驗證過的一份存在 `boot-reference.log`，可以
直接對照。以下的檢查點是**有順序的**，卡在哪一點就知道問題落在哪一層。

### R8 — HOSC 是 40 MHz、A27 跑在 960 MHz

開機前的暫存器 readback：

```
  HOSC=40 MHz（PLL_FUNC_CFG=0x00358041 DCXO_ST=0）
  PLL_CPU=0xfb002f04（EN=1 lock=1 N=48 D=2 得 960 MHz）  A27_CLK=0x84000000（SEL=CPU_PLL）
  ==> A27 CPU clock = 960 MHz
```

mainline 沒有 CCU driver，`/sys/kernel/debug/clk/clk_summary` 在這個 build 只有表頭，
所以這三行暫存器就是「CPU 到底跑多快」唯一的硬證據。欄位語意出自 SDK 的
`include/arch/sun300iw1p1/clock_autogen_aon.h`：`PLL_FUNC_CFG`(0x404) bit31 `DCXO_ST`
是 0 代表 40 MHz，`A27L2_CLK_REG`(0x588) 的 `SEL[26:24]` 是 4 代表 CPU_PLL。

`N=48 D=2` 對應 SDK `clock.c:601-627` 的 40 MHz 分支。舊版無條件寫 24 MHz 那組
（`N=40 D=1`），在這塊 40 MHz 的板子上等於 1600 MHz，也就是一直在超頻。

### R9 — A27 真的出 reset 了

```
  START_ADD 回讀：0x83f00000（要 0x83f00000）
#YWV
```

`#` 是 stub 的第一個字元，`Y`/`W`/`V` 分別是寫完 `mcache_ctl`、`mmisc_ctl`、
準備跳進 OpenSBI。看到 `#` 就證明 A27 離開 reset 並在執行我們的程式碼——這是
整個專案卡最久的一關（FEL 的 `xfel exec` 執行的是 E907，而 E907 物理上沒有
Supervisor mode）。

`START_ADD` 回讀不符時程式會直接停住不放核出來，因為在解 cfg reset 之前那個寫入
會被忽略。

### R10 — kernel 進到 S-mode 並拿到 console

```
A3478
OpenSBI v1.8
Boot HART Base ISA          : rv32imafdcnx
Linux version 7.0.0-rc4-ga0c83177734a-dirty
ttyS0 at MMIO 0x42500000 (irq = 12, base_baud = 12000000) is a 16550A
```

`A3478` 是 `head.S` 的 marker（進 S-mode / 清 sie+sip / 寫完 scounteren /
setup_vm 之前 / 開 MMU 之前），來自 `patches/linux-02-early-uart-markers.patch`。
banner 裡的 `ga0c83177734a` 證明跑的就是釘住的那顆 commit。
（沒有 `-rc4-00315-` 這種 commit 數，是因為 `scripts/fetch.sh` 用淺層 fetch 抓單一 commit，
樹裡沒有 tag，`scripts/setlocalversion` 的 `git describe` 就退回只印 `-g<sha>`。
`-dirty` 是因為 patch 是以工作區改動的形式套上去的，沒有 commit。）

### R11 — timer 頻率正確

```
TMR_A=4.10
TMR_B=9.16
```

兩次 `/proc/uptime` 中間夾一個 `sleep 5`，差值要接近 5.0。這驗的是 dts 的
`timebase-frequency = <40000000>` 跟 PLMT 的實際 mtime 速率一致。差太多就是
那個數字寫錯了。

沒有 `andestech,plmt0` 這個節點的話，kernel 找不到 clocksource、退回 `jiffies`、
拿不到 timer tick，會直接卡在 cpuidle，所有時間戳都是 `[0.000000]`。

### R12 — 開到互動 shell

```
>>> V821 rv32 mainline on A27 (S-mode, own OpenSBI via FEL).
/ #

>>> SHELL on A27!
```

從放核出 reset 到這裡約 12 秒。

### R13 — 輸入 round-trip 與 PLIC 中斷

`make boot` 結束後板子還活著（felcpux 只是關掉 host 端的序列埠），接上打字：

```
/ # echo hi
hi
/ # cat /proc/interrupts
           CPU0
 10:       1908 RISC-V INTC   5 Edge      riscv-timer
 12:        100 SiFive PLIC   3 Edge      ttyS0
```

`hwirq 3` 對應 dts 的 `interrupts-extended = <&plic 3 4>`。

但 boot log 裡的 `irq = N` 只證明 DT 屬性被解析、PLIC domain 有對應到——**hwirq
寫錯一樣會印出非零的 N**。決定性的是計數要隨打字上升，那需要真的走到線上：

```
打字前 ttyS0 中斷計數: 165
送入若干字元後:        452     （上升 287）
```

這條路徑先前是關掉的。舊紀錄裡「第一次輸入就 silent reset」是在 **vendor
OpenSBI** 底下觀察到的，而那顆 firmware 同時也是 62 秒 deadman、fid-33 ebreak halt
與各種抓不到的 CSR reset 的來源。換成自編的 OpenSBI master 之後這條路從來沒重測過，
這次一併驗了：打字全程沒有 reset。

### R14 — 慢速態對照組

```sh
make boot-nopll
```

```
  --no-pll：A27 mux 切回 HOSC（40 MHz）
```

只把 mux 切回 HOSC，PLL 不動，所以對照組跟正常組只差 mux 這一項。開機到 shell
要 ~205 秒（正常是 ~12 秒），視窗開到 700 秒。只用來取對照數據，平常不要用。

---

## 已知還沒有答案的

`SEL=0` 的絕對頻率沒有量到。欄位表標示是 HOSC，若真的是 40 MHz，相對 960 MHz
應該慢 24 倍，但實測 kernel 慢 365 倍、原廠 boot0 的時間戳慢約 1270 倍。差一到
兩個數量級。可能是那個狀態下的來源並非那顆 40 MHz DCXO（例如退到 RC1M），也
可能慢的成因不只時脈。**沒有任何暫存器會報告 A27 實際跑幾 Hz**，所以這件事只能
靠量測。它對其他結論沒有影響，留成 open item 而不是猜一個數字填上去。

板子上沒有任何暫存器會報告 A27 實際跑幾 Hz，所以絕對頻率一律以 `0x4A010000` 的
`N`/`D` 加 `0x4A010588` 的 mux 選擇推導（40 MHz × N ÷ D），不是量出來的。
