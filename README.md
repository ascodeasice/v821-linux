# mainline Linux on Allwinner V821 (RV32)

Running **mainline Linux** (base commit `a0c83177734a`, 315 commits after v7.0-rc4) on
the **Andes A27L2** core of an **Allwinner V821 / sun300iw1p1** (100ask AvaotaF1):
RV32IMAC + sv32, S-mode, self-built OpenSBI, built-in initramfs, about 12 seconds to
an interactive busybox shell.

Delivery goes over **FEL** (USB) and is **write-free** throughout: nothing is written
to NOR or SD, and a power cycle returns the board to its factory Tina Linux.

The kernel change is **2 files, 25 added lines**. The device tree is **77 substantive
lines across 12 nodes** (the vendor's `passed.dts` is 2472 lines). The kernel config is
expressed as a **117-line defconfig**. Those three things plus the A27 wake-up
sequence are the entire port.

The full development write-up, including the dead ends and the reasoning behind each
decision, is here: <https://hackmd.io/_WsFDR1QTGmC79huqfH6xA?view>

---

## What is in this repo

```
.
├── Makefile          build DAG: dts → dtb → kernel → fw_payload → verify → check → boot
├── build.sh          one-shot: check tools → fetch sources → build → run the host gates
├── pins.env          the pinned upstream commits
├── boot/             what ends up on the board: device tree and A27 entry stub
├── config/           kernel and busybox config, plus the diff against upstream
├── initramfs/        initramfs contents, including the rv32 busybox in prebuilt/
├── patches/          every change to the kernel and OpenSBI
├── scripts/          fetching sources, the pre-flight checks, the FEL wake-up
└── RESULTS.md        every claim, with the command that reproduces it
```

The four things worth reviewing:

| File | What it is |
|---|---|
| `boot/v821-min.dts` | the minimal device tree: 77 substantive lines, plus a comment on each node saying why it survived |
| `config/config-diff.txt` | what differs from the upstream `rv32_defconfig`, 361 lines, both sides `savedefconfig` output |
| `scripts/felcpux.py` | **the A27 wake-up sequence** — the crux of the whole port, see "Why the A27 needs a host-side wake-up" below |
| `patches/linux-01/02-*.patch`, `patches/opensbi-01-*.patch` | every change to the kernel and OpenSBI |

The rest:

| File | Purpose |
|---|---|
| `scripts/fetch.sh` | fetch linux and opensbi at the pinned commits and apply the patches |
| `scripts/check-tools.sh` | prove the toolchain really builds rv32, not just that gcc exists |
| `scripts/check-image.sh` | the static gate before flashing, see R3/R4 in `RESULTS.md` |
| `scripts/verify-fw.sh` | dig the embedded FDT back out of `fw_payload.bin` and read it |
| `scripts/config-diff.sh` | regenerate both `config/` artifacts from the current `.config` |
| `boot/a27_stub.S` + `boot/a27_stub.bin.golden` | where the A27 lands out of reset, 134 bytes |
| `config/v821_rv32_defconfig`, `config/busybox-rv32.config` | kernel and busybox config |
| `initramfs/init.sh`, `initramfs/initramfs.list.in` | initramfs contents |
| `initramfs/prebuilt/` | the rv32 busybox; why it is prebuilt is in `initramfs/prebuilt/README.md` |

---

## What you need

Arch:

```sh
sudo pacman -S riscv64-linux-gnu-gcc riscv64-linux-gnu-binutils \
               dtc python python-pyserial bison flex bc git make
```

Debian / Ubuntu:

```sh
sudo apt install gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu \
                 device-tree-compiler python3 python3-serial bison flex bc git make
```

`xfel` (only needed to touch the board) has to be built:

```sh
git clone https://github.com/xboot/xfel && cd xfel && make && sudo make install
```

Plus a udev rule, or xfel needs sudo:

```sh
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1f3a", ATTR{idProduct}=="efe8", MODE="0666"' \
  | sudo tee /etc/udev/rules.d/99-xfel.rules
sudo udevadm control --reload
```

For the serial port, add yourself to `uucp` (Arch) or `dialout` (Debian).

Check everything at once:

```sh
make tools
```

It does more than `command -v`: it compiles an rv32 object, does an
`rv32imafdc/ilp32d` freestanding link, and runs OpenSBI's own LD_PIE probe.

**One toolchain limitation**: the distro `riscv64-linux-gnu-*` has no rv32 libc, so
userspace does not build. The kernel, OpenSBI and the stub are all freestanding and
unaffected. busybox is therefore prebuilt; the reasoning and the rebuild instructions
are in `initramfs/prebuilt/README.md`.

To use the XuanTie set (the one originally verified on hardware):
`make CROSS=/abs/path/to/riscv64-unknown-linux-gnu-`.

---

## One-shot build

```sh
git clone <repo> && cd v821-linux
./build.sh
```

It stops at "Static checks passed". This step never touches the board.

## Step by step

```sh
make tools    # prove the toolchain builds rv32
make src      # fetch linux and opensbi at the pins.env commits, apply the patches
make dtb      # dtc -O dtb -p 0x4000
make kernel   # Image, with the initramfs already built in
make fw       # OpenSBI packs kernel and dtb into fw_payload.bin
make verify   # dig the embedded FDT back out and read it
make check    # verify + static scan. The last host-side gate
make boot     # boot over FEL
```

A few things that cannot be skipped:

- **`dtc -p 0x4000`**: OpenSBI fixes this FDT up in place (`lla a1, fw_fdt_bin` in
  `fw_base.S`), and the padding is the room `fdt_open_into()` needs to grow it.
- **`unexport O`**: kernel kbuild takes `O=` as its output directory, but OpenSBI's
  `Makefile:24` also has an `ifdef O`, and make promotes environment variables to make
  variables. Merely having `O` exported in the shell makes OpenSBI drop `fw_payload`
  into that directory — "make succeeded but the flashed image is the old one".
- **`make check`, not `make verify`**: green has to include the static scan. See the
  next section.
- **an absolute path for `CROSS`**: `make -C` runs inside the kernel tree, so a
  relative path resolves there instead, and kconfig's `syncconfig` dies up front with
  `C compiler not found`.

### Why `make check` exists

After a toolchain change there are two failures that leave the board **completely
silent**, with symptoms identical to "never entered FEL". Debugging that by power
cycling is expensive, and both are catchable on the host with one command:

1. **The stub gets contaminated by default PIE or a build-id note.** Distro gcc is
   usually `--enable-default-pie`; `-Ttext=` with default PIE emits `R_RISCV_RELATIVE`
   relocations nobody applies, and the build-id note lands below `0x83f00000` where
   `objcopy` places it ahead of the code, so the first thing the A27 executes out of
   reset is a note header. Hence `-fno-pie -no-pie -Wl,--build-id=none` on the build
   line, plus a `cmp` against the 134-byte golden binary in the repo — any difference
   fails the build.
2. **gcc emits an instruction the A27 does not have.** `arch/riscv/Makefile:83,86`
   keys off `CONFIG_TOOLCHAIN_HAS_ZACAS/ZABHA` (what the toolchain can do) rather than
   `CONFIG_RISCV_ISA_ZACAS` (what we asked for), so binutils 2.38+ lets
   `_zacas_zabha` into `-march` and authorises gcc to emit `amocas.*` and
   byte/halfword `amo*.b/.h`. One objdump scan; any hit fails the build.

---

## On the board

Hold the FEL button, replug USB-OTG, and confirm:

```sh
xfel version     # must report V821
```

Then:

```sh
make boot
```

The checkpoints are **ordered** — wherever it stops tells you which layer the problem
is in. The full list and what each one means is in `RESULTS.md`; in summary:

| Order | What you see | Meaning |
|---|---|---|
| 1 | `HOSC=40 MHz`, `==> A27 CPU clock = 960 MHz` | the clock setup took effect |
| 2 | `START_ADD readback: 0x83f00000` | the write stuck (it is ignored before the cfg reset is deasserted) |
| 3 | `#YWV` | the A27 is out of reset and running our stub |
| 4 | `OpenSBI v1.8` banner | the M-mode firmware is up |
| 5 | `A3478`, `Linux version 7.0.0-rc4-ga0c83177734a-dirty` | the kernel reached S-mode |
| 6 | `ttyS0 at MMIO 0x42500000` | the console is up |
| 7 | `/ #`, `>>> SHELL on A27!` | booted to a shell |

The log is also written to `build/felcpux.log`; a verified copy is kept in
`boot-reference.log` to diff against.

**FEL is one-shot**: once the board boots it has left FEL, so another `make boot` needs
the FEL button and a replug. Do not loop it — after a reset the board often sits in a
junk state and you never get a clean window.

---

## The four things to look at

### 1. The minimal device tree

The whole file is `boot/v821-min.dts` (168 lines, 91 of them comments explaining why).
These are all the nodes:

```
/ (allwinner,v821 / allwinner,sun300iw1p1)
├── chosen              bootargs: earlycon=uart8250,mmio32 + console=ttyS0
├── aliases             serial0
├── cpus                timebase-frequency = 40000000
│   └── cpu@0           andestech,a27; riscv,isa-base=rv32i + isa-extensions; sv32
│       └── interrupt-controller   riscv,cpu-intc
├── memory@80000000     64 MB
├── reserved-memory
│   └── opensbi@80fc0000
└── soc
    ├── serial@42500000            snps,dw-apb-uart, reg-shift 2, clock 192 MHz
    ├── interrupt-controller@48000000   riscv,plic0, ndev 187
    └── timer@48400000             andestech,plmt0
```

The design rule is "what the kernel **actually dereferences** before it has a rootfs",
not "what the chip has". The path from `Starting kernel` to mounting a rootfs is
short: memblock needs `/memory` and `/reserved-memory`, the ISA/MMU decision needs
`/cpus/cpu@0`, `time_init` needs `timebase-frequency`, `init_IRQ` needs cpu-intc and
the PLIC, and the console needs UART0. Everything else goes — 2472 lines down to 77.

Three easy traps, each with a comment in the file:

- **No `riscv,isa`**, only `riscv,isa-base` + `riscv,isa-extensions`. The kernel's
  `riscv_early_of_processor_hartid()` reads `isa-base` first and only falls through to
  `old_interface` when it is absent (commit `c98f136aedbd`). The cost is that OpenSBI
  v1.4's `fdt_parse_isa_all_harts()` only understands the legacy property, so this dts
  on v1.4 hangs silently in `sbi_hart_hang()` before the console is up. The upstream
  master this repo uses does not have that problem.
- **UART0's `clock-frequency` must be 192 MHz** (`pll-peri-cko-192m`, i.e. the factory
  log's `base_baud=12000000` x 16). Get it wrong and the baud rate is wrong and the
  screen is garbage.
- **`andestech,plmt0` must be present.** Without it the kernel finds no clocksource,
  falls back to `jiffies`, gets no timer tick and hangs at cpuidle with every
  timestamp reading `[0.000000]`.

### 2. The kernel config

`config/v821_rv32_defconfig` is 117 lines and expands to a 2031-line `.config`. The
differences are in `config/config-diff.txt`, which is the diff of two `savedefconfig`
outputs, so what you read is the decisions actually made: 25 switches deliberately
turned off and 23 settings.

Turned off (each one is either absent on this board or unused):

```
PERF_EVENTS  STRICT_KERNEL_RWX  BLK_DEV  SERIO  HID_SUPPORT  USB_SUPPORT
INPUT_KEYBOARD  INPUT_MOUSE  VIRTIO_MENU  RISCV_BOOT_SPINWAIT
RISCV_ISA_V / ZAWRS / ZABHA / ZACAS / ZBA / ZBB / ZBC / ZBKB
RISCV_ISA_ZICBOM / ZICBOZ / ZICBOP
RISCV_ISA_VENDOR_EXT_ANDES / MIPS / SIFIVE / THEAD
```

The three additions that matter: `CONFIG_ARCH_RV32I` + `CONFIG_NONPORTABLE` (RV32
cannot be selected without it), `CONFIG_RISCV_SBI_V01`, and `CONFIG_INITRAMFS_SOURCE`
(injected by the Makefile at build time, because it is an absolute path and writing it
into the defconfig would tie that file to one machine).

Running `scripts/diffconfig` on the raw `.config` instead gives 4101 lines, of which
3999 are cascaded removals from switching off the top-level options — not worth
reading, which is why it is not used.

### 3. Why the A27 needs a host-side wake-up

This is the part of the port that took longest, and the reason `scripts/felcpux.py`
exists.

The V821 has two RISC-V cores: the **T-Head E907** is the boot MCU and **physically
has no Supervisor mode**; the **Andes A27L2** is the application core that runs Linux.
And `xfel exec` runs on the **E907**.

So the `scounteren` faults, the missing S bit in `misa`, `MEDELEG=0`, needing force-S,
and the pile of CSR guards debugged early on are all symptoms of one root cause: **the
code was running on the wrong core**. force-S cannot help, because the E907 has no
S-mode to force.

Porting BOOT0's wake-up sequence faithfully into `tramp_init.S` for the E907 to run
does not work either — writing `0x49100204` faults, because in FEL/FES state the
E907's CPU bus cannot reach the CPUX_CFG block. The decisive probe was that
`xfel read32 0x49100204` returns data without faulting: **the BROM/FEL access path can
reach it, the core just has to come out of reset first**.

So the wake-up sequence runs on the host, poked in one word at a time through xfel
(`scripts/felcpux.py`):

```python
wr32(APP_RESET, rd32(APP_RESET) & ~0x1C000000)   # push the A27 back into reset first
run("ddr"); run("write", 0x80000000, fw); run("write", 0x83f00000, stub)
rmw(WAKUP_CTRL, 0x100)                            # CPUX_WUK_EN
setup_pll(...)                                    # PLL_CPU 960 MHz, A27 mux to CPU_PLL
wr32(MT_CLK, 0x80000000)                          # peripheral clocks
rmw(APP_RESET, 0x18000000)                        # msgbox / cfg reset deassert
wr32(CPUX_START, 0x83f00000)                      # entry address
assert rd32(CPUX_START) == 0x83f00000             # ignored before the cfg reset is deasserted
wr32(CPUX_WFI_MODE, 0)
rmw(APP_RESET, 0x04000000)                        # cpu reset deassert, the A27 runs
```

Every address and field meaning comes from the SDK's
`spl/board/sun300iw1p1/e907_boot/boot0_main.c`, `clock.c` and
`include/arch/sun300iw1p1/clock_autogen_aon.h`.

Two details worth calling out:

- **Push it back into reset before touching DRAM.** On a rerun the A27 is still
  executing the previous round's code, `xfel ddr` reinitialises the DRAM controller
  underneath it, and the 10 MB payload write collides with its instruction fetches.
  That is the intermittent soft reboot behind "the stub printed `#YWV` and then
  OpenSBI said nothing".
- **The PLL has two constant sets keyed on HOSC.** Both branches of SDK
  `clock.c:601-627` land on 960 MHz: 40 MHz uses `N=48 D=2`, 24 MHz uses `N=40 D=1`.
  An earlier version wrote the 24 MHz set unconditionally, which on this 40 MHz board
  is `40*40/1 = 1600 MHz` — permanently overclocked. It now reads `DCXO_ST` from
  `PLL_FUNC_CFG` to determine HOSC before choosing.

Out of reset the A27 lands in `boot/a27_stub.S` (134 bytes): set `mcache_ctl`(0x7ca)
and `mmisc_ctl`(0x7d0), `fence.i`, then jump to `0x80000000` with `a0=mhartid, a1=0`.
It **deliberately does not touch `0x7c0`** — that is the E907's T-Head `mxstatus`,
which on the Andes A27 is something else entirely and faults.

### 4. The kernel and OpenSBI changes

The kernel side is 2 files, 25 added lines:

- `patches/linux-01-alternative-workaround.patch` — `apply_boot_alternatives()`
  returns immediately. The RV32 alternative pass resolves a wrong `old_ptr` and takes
  a load page fault in `__patch_insn_write()`. We run a minimal rv32imac config with
  no errata and no Z-ext alternatives, so the unpatched default path is the correct
  baseline. **Not root-caused yet, so not upstreamable.**
- `patches/linux-02-early-uart-markers.patch` — early UART markers in `head.S`. There
  is no console before the MMU is on; this is a debugging aid, not a requirement of
  the port.

OpenSBI is upstream master `547a5bb` plus one patch touching 7 files, which:

- **Removes `CLEAR_MDT` from `fw_base.S`.** It touches `mstatush` (Smdbltrp), which
  the A27 does not have. This code runs before `mtvec` is set and before any C, so the
  symptom is complete silence after `#YWV`.
- Adds `csr_write(CSR_MISA, misa | S)` early in `sbi_hart_init` — the A27's misa does
  not advertise S.
- Skips the `SCOUNTEREN` / `MENVCFG` / `MSTATEEN0` / `SATP` writes and the
  optional-CSR probing that cause uncatchable resets on the A27.
- Sets `mhpm_mask = 0` (the A27 uses XAndesPMU instead).
- Adds a small console driving UART0 directly, registered in `init_coldboot`, because
  the dw-apb fdt-serial probe hangs on this core.

`make patch-check` verifies these still line up with the pinned commits by
reverse-applying with `git apply --check -R`. Reverse is stricter than forward: it
proves both that the change is present in the tree and that nothing else overwrote it.

---

## Changing things

| What you want to change | Where | What to run afterwards |
|---|---|---|
| device tree | `boot/v821-min.dts` | `make verify` |
| kernel config | `make menuconfig` | `make config-diff` to refresh `config/v821_rv32_defconfig` and `config/config-diff.txt` |
| initramfs contents | `initramfs/initramfs.list.in`, `initramfs/init.sh` | `make kernel` |
| toolchain | `make CROSS=...` | `make tools`, then `make check` |
| kernel / OpenSBI version | `pins.env` | `make src`; expect to redo the patches |
| bootargs | `/chosen` in `boot/v821-min.dts` | `make verify` to confirm it really got packed |

Always `make check` before going to the board.

---

## When it gets stuck

| Symptom | Usually |
|---|---|
| `xfel version` does not report V821 | not in FEL (hold the button while plugging in), or the udev rule is missing |
| no characters at all, not even `#` | the stub is broken. Run `make check` and see whether the golden `cmp` passes |
| `#YWV` and then silence | OpenSBI died early. Usually an M-mode CSR — see `patches/opensbi-01` |
| starts fine, then all garbage | the UART `clock-frequency` is wrong; it should be 192 MHz |
| stuck at `[0.000000]` | the PLMT node is missing, so the kernel gets no timer tick |
| extremely slow boot (~205 s) | the A27 is on HOSC and never switched to CPU_PLL; check the `==> A27 CPU clock` line |
| make is green but the flashed image looks old | `O` is exported in your shell and collides with OpenSBI's `O` |
| `/dev/ttyUSB*` will not open | another program holds it (`fuser /dev/ttyUSB0`), or you are not in uucp/dialout |

The board cannot be bricked this way: the whole delivery path writes to no
non-volatile storage, and a power cycle boots the factory Tina Linux 5.4.220 from NOR.

---

## What is not here

- **SD card boot.** FEL is the only path right now, so USB has to be attached. See the
  roadmap below.
- **The serial XMODEM fallback path** (vendor U-Boot + `loadx` + `bootm`). It works,
  but it is far slower than FEL (seven minutes for 4.7 MB), and it stays in the old
  repo.
- **The record of the dead ends** (TLB/icache bisection patches, the OpenSBI v1.4
  patches, the early FEL trampoline). Those stay in the old repo's
  `mainline/patches/`.
- **Any driver beyond UART / PLIC / PLMT.** No CCU, no pinctrl, no mmc — which is why
  `clk_summary` is empty and the CPU clock can only be confirmed from the register
  values `scripts/felcpux.py` prints.
- **The vendor Tina SDK** (18 GB) and the NOR backup (32 MB). To recreate the backup:
  `xfel spinor read 0 0x2000000 nor_full_backup.bin`.

## Current status and next step

**Working**: FEL load → self-built OpenSBI → mainline Linux (S-mode, A27) → built-in
initramfs → interactive busybox shell, in about 12 seconds. Input works, and UART0
runs on PLIC interrupts (on hardware: `irq = 12`, hwirq 3, and the `/proc/interrupts`
count rises while typing).

Early on there was a known limitation: "the first keystroke after reaching the shell
causes a silent reset". That was observed under the **vendor OpenSBI**, the same
firmware behind the 62-second deadman and assorted uncatchable CSR resets. It was
never retested after switching to a self-built OpenSBI master, and this run ruled it
out.

**Not solved**: the absolute frequency at `SEL=0` (A27 on HOSC) has never been
measured, and the measured slowdown is one to two orders of magnitude larger than the
field table predicts. No register reports the rate the A27 actually runs at, so this
can only be settled by measurement. See the last section of `RESULTS.md`.

**The next milestone is SD card boot**, so the board can come up without a host. That
the BROM loads boot0 from sector 16 of the SD card is already demonstrated (with the
eGON header on NOR wiped, a cold boot with an SD card inserted still comes up). The
vendor SDK ships a prebuilt `boot0_sdcard_sun300iw1p1.bin` and a U-Boot with `booti`
and `mmcinfo` (the spinor build on the board has no `booti`, which is exactly why the
old repo has a `mkuimage.py`). What remains unknown is mostly the sunxi SD partition
and offset layout. It will arrive as its own directory; nothing in this repo currently
presumes it exists.

"Linux mounting its rootfs from SD" is a separate matter — it means porting
`allwinner,sunxi-mmc-v5p3x` and `sun300iw1-pinctrl` to mainline, which is open-ended
engineering and, by this project's minimality rule, not needed.

---

## Sources

- The full development write-up, including every dead end and the reasoning:
  <https://hackmd.io/_WsFDR1QTGmC79huqfH6xA?view>
- Register addresses and field meanings come from the `sun300iw1p1` parts of the
  Allwinner Tina Linux SDK.
- `xfel` — https://github.com/xboot/xfel
- OpenSBI — https://github.com/riscv-software-src/opensbi

See `LICENSE`: the kernel-derived parts are GPL-2.0, the OpenSBI patch is BSD-2-Clause.
