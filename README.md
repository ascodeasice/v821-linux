# mainline Linux on Allwinner V821 (RV32)

把 **mainline Linux**（base commit `a0c83177734a`，v7.0-rc4 之後 315 個 commit）跑在
**Allwinner V821 / sun300iw1p1**（百問網 AvaotaF1）的 **Andes A27L2** 核上，RV32IMAC + sv32、
S-mode、自編 OpenSBI、內建 initramfs，開到互動 busybox shell 約 12 秒。

交付走 **FEL**（USB），全程 **write-free**：不寫 NOR、不寫 SD，斷電重開就回到原廠 Tina Linux。

kernel 的改動是 **2 個檔、27 行**。device tree 是 **77 行、12 個節點**（vendor 的
`passed.dts` 是 2472 行）。kernel config 用 **112 行的 defconfig** 表述。這三樣加上
A27 的喚醒序列，就是這個移植的全部。

---

## 這個 repo 有什麼

四個要拿給人審查的東西都在頂層：

| 檔案 | 是什麼 |
|---|---|
| `v821-min.dts` | 最小 device tree，77 行實體 + 逐項寫明為什麼留下的註解 |
| `config-diff.txt` | 與上游 `rv32_defconfig` 的差異，363 行，兩邊都是 `savedefconfig` 輸出 |
| `felcpux.py` | **A27 的喚醒序列**。這是整個移植最關鍵的一段——見下面「A27 為什麼要 host 端喚醒」 |
| `linux-01/02-*.patch`、`opensbi-01-*.patch` | kernel 與 OpenSBI 的全部改動 |

其餘：

| 檔案 | 用途 |
|---|---|
| `Makefile` | 建置 DAG：dts → dtb → kernel → fw_payload → verify → check → boot |
| `pins.env` | 釘住的上游 commit |
| `fetch.sh` | 抓 linux 與 opensbi 到釘住的 commit 並套 patch |
| `build.sh` | 一鍵：檢查工具 → 抓原始碼 → 編 → 跑上板前的靜態關卡 |
| `check-tools.sh` | 驗 toolchain 真的編得出 rv32，不是只看 gcc 在不在 |
| `check-image.sh` | 上板前的靜態關卡，見 `RESULTS.md` 的 R3/R4 |
| `verify-fw.sh` | 把內嵌的 FDT 從 `fw_payload.bin` 挖回來驗 |
| `a27_stub.S` + `.bin.golden` | A27 出 reset 後的落地點，134 bytes |
| `init.sh`、`cycfreq.c`、`busybox-rv32.config` | initramfs 的內容 |
| `prebuilt/` | rv32 的 busybox 與 cycfreq，為什麼要 prebuilt 見 `prebuilt/README.md` |
| `RESULTS.md` | 每個宣稱對應一條可以跑的指令與預期證據行 |

---

## 需要的東西

Arch：

```sh
sudo pacman -S riscv64-linux-gnu-gcc riscv64-linux-gnu-binutils \
               dtc python python-pyserial bison flex bc git make
```

Debian / Ubuntu：

```sh
sudo apt install gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu \
                 device-tree-compiler python3 python3-serial bison flex bc git make
```

`xfel`（只有上板才需要）要自己編：

```sh
git clone https://github.com/xboot/xfel && cd xfel && make && sudo make install
```

還要一條 udev rule，否則得用 sudo 跑 xfel：

```sh
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1f3a", ATTR{idProduct}=="efe8", MODE="0666"' \
  | sudo tee /etc/udev/rules.d/99-xfel.rules
sudo udevadm control --reload
```

序列埠要把自己加進 `uucp`（Arch）或 `dialout`（Debian）群組。

確認一次：

```sh
make tools
```

它不是只查 `command -v`，而是真的去編 rv32 的 object、做 `rv32imafdc/ilp32d` 的
freestanding link、跑一次 OpenSBI 自己那個 LD_PIE 探測。

**toolchain 的一個限制**：發行版的 `riscv64-linux-gnu-*` 沒有 rv32 的 libc，
所以 userspace 編不出來。kernel、OpenSBI、stub 都是 freestanding，不受影響。
busybox 與 cycfreq 因此用 prebuilt，理由與重編方式見 `prebuilt/README.md`。

要用 XuanTie 那套（原本實機驗過的）就 `make CROSS=/abs/path/to/riscv64-unknown-linux-gnu-`。

---

## 一鍵建置

```sh
git clone <repo> && cd v821-linux
./build.sh
```

跑完會停在「靜態檢查通過」。這一步不碰板子。

## 一步一步

```sh
make tools    # 驗 toolchain 編得出 rv32
make src      # 抓 linux 與 opensbi 到 pins.env 釘的 commit，套 patch
make dtb      # dtc -O dtb -p 0x4000
make kernel   # Image，initramfs 已經編進去
make fw       # OpenSBI 把 kernel 與 dtb 包成 fw_payload.bin
make verify   # 把內嵌的 FDT 挖回來看
make check    # verify + 靜態掃描。最後一道 host 端關卡
make boot     # 進 FEL 開機
```

幾個不能省的地方：

- **`dtc -p 0x4000`**：OpenSBI 是原地 fixup 這顆 FDT（`fw_base.S` 的 `lla a1, fw_fdt_bin`），
  padding 就是 `fdt_open_into()` 撐大時要用的空間。
- **`unexport O`**：kernel kbuild 用 `O=` 指定輸出目錄，但 OpenSBI 的 `Makefile:24` 也有
  `ifdef O`，而 make 會把環境變數當成 make 變數。shell 裡只要 export 過 `O`，OpenSBI
  就會把 `fw_payload` 蓋到那個目錄，於是「make 明明成功、燒上去的卻是舊的」。
- **`make check` 而不是 `make verify`**：綠燈必須包含靜態掃描。理由見下一節。
- **`CROSS` 帶路徑時一律轉絕對路徑**：`make -C` 會切到 kernel tree 執行，相對路徑會被
  解析到那邊去，kconfig 的 `syncconfig` 會在最前面就以 `C compiler not found` 死掉。

### 為什麼有 `make check`

換 toolchain 之後有兩種失敗會讓板子**完全靜音**，而且症狀跟「沒進 FEL」一模一樣。
用 power-cycle 去 debug 這種東西很貴，但兩種都可以在 host 上一行指令抓出來：

1. **stub 被 default PIE 或 build-id note 汙染**。發行版 gcc 多半是 `--enable-default-pie`；
   `-Ttext=` 配 default PIE 會產生沒人套用的 `R_RISCV_RELATIVE`，build-id note 則會拿到
   `0x83f00000` 以下的位址、被 `objcopy` 排在 code 前面，A27 出 reset 第一件事就是執行
   note header。所以 build line 帶 `-fno-pie -no-pie -Wl,--build-id=none`，而且跟 repo 裡
   那份 134 bytes 的 golden binary `cmp`，不同就直接 build 失敗。
2. **gcc 發出 A27 沒有的指令**。`arch/riscv/Makefile:83,86` 看的是
   `CONFIG_TOOLCHAIN_HAS_ZACAS/ZABHA`（toolchain 有沒有能力）而不是 `CONFIG_RISCV_ISA_ZACAS`
   （我們有沒有要用），binutils 2.38 以上會讓 `_zacas_zabha` 進 `-march`，gcc 就被授權發
   `amocas.*` 與 byte/halfword 的 `amo*.b/.h`。objdump 掃一次，有命中就 build 失敗。

---

## 上板

按住 FEL 鈕、重插 USB-OTG，確認：

```sh
xfel version     # 要看得到 V821
```

然後：

```sh
make boot
```

檢查點是**有順序的**，卡在哪一點就知道問題落在哪一層。完整清單與每一項的意義在
`RESULTS.md`，摘要：

| 順序 | 看到什麼 | 代表 |
|---|---|---|
| 1 | `HOSC=40 MHz`、`==> A27 CPU clock = 960 MHz` | 時脈設定生效 |
| 2 | `START_ADD 回讀：0x83f00000` | 寫入 stick 了（解 cfg reset 之前會被忽略） |
| 3 | `#YWV` | A27 出 reset 並在跑我們的 stub |
| 4 | `OpenSBI v1.8` banner | M-mode firmware 起來了 |
| 5 | `A3478`、`Linux version 7.0.0-rc4-00315-ga0c83177734a` | kernel 進 S-mode |
| 6 | `ttyS0 at MMIO 0x42500000` | console 拿到了 |
| 7 | `/ #`、`>>> SHELL on A27!` | 開到 shell |

log 同時寫到 `build/felcpux.log`。已驗證的一份存在 `boot-reference.log`，可以直接 diff。

**FEL 是一次性的**：板子開機之後就離開 FEL 了，要再跑一次 `make boot` 必須重新按 FEL 鈕
重插 USB。不要用迴圈連跑，reset 後板子常卡在垃圾狀態，抓不到乾淨的視窗。

---

## 要看的四件事

### 1. 最小 device tree

完整檔案是 `v821-min.dts`（162 行，其中 85 行是說明為什麼的註解）。節點只有這些：

```
/ (allwinner,v821 / allwinner,sun300iw1p1)
├── chosen              bootargs：earlycon=uart8250,mmio32 + console=ttyS0
├── aliases             serial0
├── cpus                timebase-frequency = 40000000
│   └── cpu@0           andestech,a27；riscv,isa-base=rv32i + isa-extensions；sv32
│       └── interrupt-controller   riscv,cpu-intc
├── memory@80000000     64 MB
├── reserved-memory
│   └── opensbi@80fc0000
└── soc
    ├── serial@42500000            snps,dw-apb-uart，reg-shift 2，clock 192 MHz
    ├── interrupt-controller@48000000   riscv,plic0，ndev 187
    └── timer@48400000             andestech,plmt0
```

設計原則是「kernel 拿到 rootfs 之前**實際會 dereference** 什麼」，不是「晶片有什麼」。
從 `Starting kernel` 到掛 rootfs 這條路很短：memblock 要 `/memory` 與 `/reserved-memory`，
ISA/MMU 判定要 `/cpus/cpu@0`，`time_init` 要 `timebase-frequency`，`init_IRQ` 要
cpu-intc 與 PLIC，console 要 UART0。其餘一律砍掉，2472 行變 77 行。

三個容易踩到的點，每一個都在檔案裡有註解：

- **沒有 `riscv,isa`**，只有 `riscv,isa-base` + `riscv,isa-extensions`。kernel 的
  `riscv_early_of_processor_hartid()` 先讀 `isa-base`，只有它不存在時才 goto
  `old_interface`（commit `c98f136aedbd`）。代價是 OpenSBI v1.4 的
  `fdt_parse_isa_all_harts()` 只認 legacy 屬性，配這份 dts 會在 console 起來之前
  靜默卡死在 `sbi_hart_hang()`。本 repo 用的 upstream master 沒這個問題。
- **UART0 的 `clock-frequency` 必須是 192 MHz**（`pll-peri-cko-192m`，原廠 log 的
  `base_baud=12000000` × 16）。寫錯 baud 就不對，畫面全是亂碼。
- **一定要有 `andestech,plmt0`**。沒有它 kernel 找不到 clocksource、退回 `jiffies`、
  拿不到 timer tick，直接卡在 cpuidle，所有時間戳都是 `[0.000000]`。

### 2. kernel config

`v821_rv32_defconfig` 是 112 行，展開成 `.config` 是 1991 行。差異看 `config-diff.txt`，
它是兩份 `savedefconfig` 輸出的 diff，所以看到的就是真正做過的決定：21 個主動關掉的
開關、23 項設定。

主動關掉的（每一項都是「這塊板子上沒有、或我們不用」）：

```
PERF_EVENTS  STRICT_KERNEL_RWX  BLK_DEV  SERIO  HID_SUPPORT  USB_SUPPORT
INPUT_KEYBOARD  INPUT_MOUSE  VIRTIO_MENU  RISCV_BOOT_SPINWAIT
RISCV_ISA_ZAWRS / ZACAS / ZBA / ZBB / ZICBOM / ZICBOZ / ZICBOP
RISCV_ISA_VENDOR_EXT_ANDES / MIPS / SIFIVE / THEAD
```

加上去的關鍵三項：`CONFIG_ARCH_RV32I` + `CONFIG_NONPORTABLE`（RV32 要它才選得下去）、
`CONFIG_RISCV_SBI_V01`、`CONFIG_INITRAMFS_SOURCE`（由 Makefile 在 build 時注入，
因為它是絕對路徑，寫進 defconfig 就跟機器綁死了）。

直接對 `.config` 跑 `scripts/diffconfig` 會得到 4101 行，其中 3999 行是關掉上層開關
之後的連鎖移除，沒有閱讀價值，所以不用那個。

### 3. A27 為什麼要 host 端喚醒

這是整個移植花最久的一關，也是 `felcpux.py` 存在的理由。

V821 有兩顆 RISC-V 核：**T-Head E907** 是 boot MCU，**物理上沒有 Supervisor mode**；
**Andes A27L2** 才是跑 Linux 的應用核。而 `xfel exec` 執行的是 **E907**。

所以早期一路在 debug 的 `scounteren` fault、`misa` 沒有 S、`MEDELEG=0`、需要 force-S、
一堆 CSR guard，全部是同一個根因的症狀：**程式跑在錯的核上**。force-S 救不了，因為
E907 沒有 S-mode 可以 force。

把 BOOT0 的喚醒序列忠實搬進 `tramp_init.S` 由 E907 執行也不行——寫 `0x49100204` 會
fault，E907 在 FEL/FES 狀態下的 CPU bus 到不了 CPUX_CFG block。決定性的探測是
`xfel read32 0x49100204` 讀得到而且不 fault：**BROM/FEL 的存取路徑到得了，只差先解 reset**。

於是喚醒序列跑在 host 上，透過 xfel 一格一格寫進去（`felcpux.py`）：

```python
wr32(APP_RESET, rd32(APP_RESET) & ~0x1C000000)   # 先把 A27 押回 reset
run("ddr"); run("write", 0x80000000, fw); run("write", 0x83f00000, stub)
rmw(WAKUP_CTRL, 0x100)                            # CPUX_WUK_EN
setup_pll(...)                                    # PLL_CPU 960 MHz，A27 mux 切到 CPU_PLL
wr32(MT_CLK, 0x80000000)                          # 周邊時脈
rmw(APP_RESET, 0x18000000)                        # msgbox / cfg reset deassert
wr32(CPUX_START, 0x83f00000)                      # 入口位址
assert rd32(CPUX_START) == 0x83f00000             # 解 cfg reset 之前這個寫入會被忽略
wr32(CPUX_WFI_MODE, 0)
rmw(APP_RESET, 0x04000000)                        # cpu reset deassert，A27 開始跑
```

每個位址與欄位語意都出自 SDK 的 `spl/board/sun300iw1p1/e907_boot/boot0_main.c`、
`clock.c` 與 `include/arch/sun300iw1p1/clock_autogen_aon.h`。

兩個細節值得單獨講：

- **先押回 reset 再碰 DRAM**。重跑時 A27 還在執行上一輪的東西，`xfel ddr` 會在它腳下
  重新初始化 DRAM 控制器，10 MB 的 payload 寫入又跟它的 fetch 相撞。這就是「stub 印了
  `#YWV` 然後 OpenSBI 沒聲音」那個時有時無的軟重啟。
- **PLL 依 HOSC 分兩組常數**。SDK `clock.c:601-627` 的兩組都指向 960 MHz：40 MHz 用
  `N=48 D=2`，24 MHz 用 `N=40 D=1`。舊版無條件寫 24 MHz 那組，在這塊 40 MHz 的板子上
  等於 `40*40/1 = 1600 MHz`，也就是一直在超頻。現在先讀 `PLL_FUNC_CFG` 的 `DCXO_ST`
  判斷 HOSC 再選。

A27 出 reset 後落在 `a27_stub.S`（134 bytes）：設 `mcache_ctl`(0x7ca)、`mmisc_ctl`(0x7d0)、
`fence.i`，然後 `a0=mhartid, a1=0` 跳到 `0x80000000`。它**刻意不碰 `0x7c0`**——那是 E907
的 T-Head `mxstatus`，在 Andes A27 上是別的東西而且會 fault。

### 4. kernel 與 OpenSBI 的改動

kernel 2 個檔、27 行：

- `linux-01-alternative-workaround.patch` — `apply_boot_alternatives()` 直接 return。
  RV32 的 alternative pass 會解出錯的 `old_ptr`，在 `__patch_insn_write()` 吃到 load
  page fault。我們跑最小 rv32imac config，沒有任何 errata / Z-ext alternative，未 patch
  的預設路徑就是正確的 baseline。**還沒 root-cause，所以還不能上游。**
- `linux-02-early-uart-markers.patch` — `head.S` 的早期 UART marker。MMU 還沒開就沒有
  console，這是除錯用的，不是移植的必要條件。

OpenSBI 是 upstream master `547a5bb` 加一支 patch（7 個檔），做的事：

- **`fw_base.S` 的 `CLEAR_MDT` 拿掉**。它碰 `mstatush`（Smdbltrp），A27 沒有這個東西。
  這段跑在設 `mtvec` 之前、跑在任何 C 之前，所以症狀是 `#YWV` 之後完全靜音。
- `sbi_hart_init` 早期補 `csr_write(CSR_MISA, misa | S)`——A27 的 misa 不宣告 S。
- 跳過會讓 A27 uncatchable-reset 的 `SCOUNTEREN` / `MENVCFG` / `MSTATEEN0` / `SATP` 寫入
  與 optional-CSR 探測。
- `mhpm_mask = 0`（A27 用的是 XAndesPMU）。
- 自己寫一組直驅 UART0 的 console 並在 `init_coldboot` 註冊，因為 dw-apb 的 fdt-serial
  probe 在這顆上會卡住。

`make patch-check` 用 `git apply --check -R` 反向套用來驗這些 patch 仍然對得上釘住的
commit。反向比正向嚴格：它同時證明改動確實在樹上、而且沒有被別的東西蓋掉。

---

## 要改東西的話

| 想改什麼 | 動哪裡 | 之後跑什麼 |
|---|---|---|
| device tree | `v821-min.dts` | `make verify` |
| kernel config | `make menuconfig` | `make config-diff` 把 `v821_rv32_defconfig` 與 `config-diff.txt` 更新回來 |
| initramfs 內容 | `initramfs.list.in`、`init.sh` | `make kernel` |
| 換 toolchain | `make CROSS=...` | `make tools` 再 `make check` |
| 換 kernel / OpenSBI 版本 | `pins.env` | `make src`；patch 大概要重做 |
| bootargs | `v821-min.dts` 的 `/chosen` | `make verify` 確認真的包進去了 |

改完一律 `make check` 再上板。

---

## 卡住的時候

| 症狀 | 多半是 |
|---|---|
| `xfel version` 看不到 V821 | 沒進 FEL（按住鈕再插），或缺 udev rule |
| 完全沒有任何字元，連 `#` 都沒有 | stub 壞了。先 `make check` 看 golden `cmp` 過不過 |
| 只有 `#YWV` 然後靜音 | OpenSBI 在早期掛了。多半是 M-mode CSR，看 `opensbi-01` 那支 patch |
| 開頭正常但後面全是亂碼 | UART 的 `clock-frequency` 不對，應該是 192 MHz |
| 停在 `[0.000000]` 不動 | PLMT 節點掉了，kernel 拿不到 timer tick |
| 開機超級慢（~205 秒） | A27 掛在 HOSC 沒切到 CPU_PLL，看 `==> A27 CPU clock` 那行 |
| make 綠燈但燒上去像舊的 | shell 裡 export 過 `O`，撞到 OpenSBI 的 `O` |
| `/dev/ttyUSB*` 打不開 | 別的程式佔著（`fuser /dev/ttyUSB0`），或不在 uucp/dialout 群組 |

板子怎麼弄都不會磚：整條交付路徑不寫任何非揮發性儲存，斷電重開就從 NOR 回到原廠
Tina Linux 5.4.220。

---

## 這裡沒有的東西

- **SD 卡開機**。現在只有 FEL 這條路，要接 USB。見下面的 roadmap。
- **序列埠 XMODEM 那條備援路徑**（vendor U-Boot + `loadx` + `bootm`）。能動，但比 FEL
  慢很多（4.7 MB 傳七分鐘），留在舊 repo。
- **各種死路的紀錄**（TLB/icache 的 bisection patch、OpenSBI v1.4 的 patch、FEL 早期的
  trampoline）。留在舊 repo 的 `mainline/patches/`。
- **UART / PLIC / PLMT 以外的任何 driver**。沒有 CCU、沒有 pinctrl、沒有 mmc。所以
  `clk_summary` 是空的，CPU 時脈只能靠 `felcpux.py` 印的暫存器值確認。
- **vendor 的 Tina SDK**（18 GB）與 NOR 備份（32 MB）。備份重建方式：
  `xfel spinor read 0 0x2000000 nor_full_backup.bin`。

## 目前狀態與下一步

**能動的**：FEL 載入 → 自編 OpenSBI → mainline Linux（S-mode, A27）→ 內建 initramfs
→ 互動 busybox shell，約 12 秒。

**還沒解決的**：`SEL=0`（A27 掛 HOSC）的絕對頻率沒量到，實測慢的倍數比欄位表推算的
多一到兩個數量級。沒有任何暫存器會報告 A27 實際跑幾 Hz，所以只能靠量測。詳見
`RESULTS.md` 最後一節。

**下一個里程碑是 SD 卡開機**，讓板子不接 host 也能開。BROM 會從 SD 的 sector 16 載
boot0 這件事已經實證過（把 NOR 的 eGON 標頭抹掉之後插 SD 冷開機仍然開得起來）。
vendor SDK 裡有 prebuilt 的 `boot0_sdcard_sun300iw1p1.bin`，也有帶 `booti` 與 `mmcinfo`
的 U-Boot（板上跑的 spinor 版沒有 `booti`，這正是舊 repo 那支 `mkuimage.py` 存在的原因）。
剩下的未知主要是 sunxi 的 SD 分割與 offset 佈局。它會以獨立的目錄加進來，這個 repo
現在沒有任何東西預設了它的存在。

「Linux 從 SD 掛 rootfs」是另一回事，要把 `allwinner,sunxi-mmc-v5p3x` 與
`sun300iw1-pinctrl` 移植到 mainline，是開放式工程，而且依這個專案的最小化原則並不需要。

---

## 出處

- 完整的開發日誌（含所有走過的死路與判斷過程）在舊 repo 的 `claude-report.md`。
- 暫存器位址與欄位語意出自 Allwinner Tina Linux SDK 的 `sun300iw1p1` 部分。
- `xfel` — https://github.com/xboot/xfel
- OpenSBI — https://github.com/riscv-software-src/opensbi

授權見 `LICENSE`：kernel 相關的部分是 GPL-2.0，OpenSBI 的 patch 是 BSD-2-Clause。
