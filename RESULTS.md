# RESULTS — every claim, and the command that reproduces it

For every number in the write-up, this file gives the command that reproduces it and
the evidence line to look for. Two groups: **no board required** (anyone who clones
the repo can run these) and **board required** (needs an AvaotaF1 in FEL).

Run `./build.sh` first.

---

## No board required

### R1 — two people build the same firmware

```sh
git clone <repo> /tmp/a && cd /tmp/a && ./build.sh
git clone <repo> /tmp/b && cd /tmp/b && ./build.sh
sha256sum /tmp/{a,b}/build/opensbi/build/platform/generic/firmware/fw_payload.bin
```

The two sha256 lines match.

Kernel builds are not reproducible by default; there are two sources of variance: the
build timestamp in the banner, and the file mtimes in the initramfs cpio headers
(everyone's `git checkout` runs at a different time). The `Makefile` pins
`KBUILD_BUILD_TIMESTAMP`, and that one variable covers both — the banner uses it
directly, and `usr/Makefile:67` passes it to `gen_initramfs.sh` as `-d`. For a real
build timestamp: `make KBUILD_BUILD_TIMESTAMP="$(date)"`.

### R2 — the device tree inside fw_payload is the right one

```sh
make verify
```

A green `make` does not mean the right thing was packed. The dtb was once packed
stale because `dtc` had not rerun; the board booted normally, just with the wrong
configuration, with no symptom at all. This digs the FDT back out of the firmware
blob:

```
FDT at 0x24020, totalsize=18176
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

`riscv,isa` showing `FDT_ERR_NOTFOUND` is **expected** — that is exactly what this dts
is designed to do: the new `riscv,isa-base` / `riscv,isa-extensions` interface only.
If it ever shows up, someone has added the legacy property back.

### R3 — the new toolchain emits no instruction the A27 lacks

```sh
make check
```

```
vmlinux free of Zacas/Zabha instructions       ok
```

`arch/riscv/Makefile:83,86` keys off `CONFIG_TOOLCHAIN_HAS_ZACAS/ZABHA` (what the
toolchain can do), not `CONFIG_RISCV_ISA_ZACAS` (what we asked for). binutils 2.38 and
later let `_zacas_zabha` into `-march`, which authorises gcc to emit `amocas.*` and
byte/halfword `amo*.b/.h`. The A27 has neither, and reaching one is an illegal
instruction with no handler.

By hand:

```sh
riscv64-linux-gnu-objdump -d build/kernel/vmlinux \
  | grep -E '\bamocas\.|\bamo(add|and|or|swap|xor|max|min)u?\.(b|h)\b'
```

No output means it passed.

### R4 — the stub is not contaminated by PIE or a build-id

```sh
make check
```

```
a27_stub matches golden                        ok (134 bytes)
```

Distro gcc is usually `--enable-default-pie`. The kernel and OpenSBI both switch it
off themselves; the stub's build line originally did not. `-Ttext=` with default PIE
emits `R_RISCV_RELATIVE` relocations nobody applies, and the build-id note lands below
`0x83f00000` where `objcopy -O binary` places it ahead of the code — so the first
thing the A27 executes out of reset is a note header. Both failures leave the board
completely silent, indistinguishable from "never entered FEL".

The 134-byte golden binary is checked into the repo, and a failing `cmp` fails the
build. This one check catches PIE, the build-id and codegen drift at once, for free.

### R5 — the kernel config trim is checkable

```sh
make config-diff
cat config/config-diff.txt
```

`config/v821_rv32_defconfig` is 117 lines and expands to a 2031-line `.config`.
`config/config-diff.txt` is the diff of two `savedefconfig` outputs — minimal
expressions relative to the Kconfig defaults — so what you read is the decisions
actually made: 25 switches deliberately turned off and 23 settings.

Running `scripts/diffconfig` on the raw `.config` instead gives 4101 lines, of which
3999 are cascaded removals from switching off NET / IIO / DRM and friends. Not worth
reading.

### R6 — the patches still line up with the pinned commits

```sh
make patch-check
```

```
  ok  linux-01-alternative-workaround.patch
  ok  linux-02-early-uart-markers.patch
  ok  opensbi-01-v821-a27-port.patch
```

Verified by reverse-applying with `git apply --check -R`, which is stricter than
applying forward: it proves both that the change the patch describes is present in the
tree and that nothing else has overwritten it.

### R7 — how far the device tree was minimised

```sh
grep -c '' boot/v821-min.dts                                     # 168 lines (91 of them comments)
grep -v '^\s*\*\|^\s*/\*\|^\s*//\|^\s*$' boot/v821-min.dts | grep -c ''   # 77 substantive lines
dtc -I dtb -O dts build/v821-min.dtb | grep -c '{'               # 13 (12 nodes plus root)
```

The 12 nodes are `chosen`, `aliases`, `cpus`, `cpu@0`, `cpu@0/interrupt-controller`,
`memory@80000000`, `reserved-memory`, `opensbi@80fc0000`, `soc`, `serial@42500000`,
`interrupt-controller@48000000` (PLIC) and `timer@48400000` (PLMT). Only the last five
describe hardware; the rest is metadata the kernel's early path reads.

The vendor's `passed.dts` is 2472 lines and roughly 229 nodes, with `soc@2002000`
alone taking 1800 of them. Cutting 95% of that is the core move of the whole exercise,
and the reason each surviving node is there is written in the dts comments.

---

## Board required (one power cycle covers all of it)

Hold the FEL button, replug USB-OTG, confirm `xfel version` reports V821, then:

```sh
make boot
```

The log is also written to `build/felcpux.log`; a verified copy is kept in
`boot-reference.log` for comparison. The checkpoints below are **ordered** — wherever
it stops tells you which layer the problem is in.

### R8 — HOSC is 40 MHz and the A27 runs at 960 MHz

Register readback before boot:

```
  HOSC=40 MHz (PLL_FUNC_CFG=0x00358041 DCXO_ST=0)
  PLL_CPU=0xfb002f04 (EN=1 lock=1 N=48 D=2 gives 960 MHz)  A27_CLK=0x84000000 (SEL=CPU_PLL)
  ==> A27 CPU clock = 960 MHz
```

Mainline has no CCU driver, so `/sys/kernel/debug/clk/clk_summary` in this build has
nothing but a header, which makes these three register lines the only hard evidence of
how fast the CPU actually runs. The field meanings come from the SDK's
`include/arch/sun300iw1p1/clock_autogen_aon.h`: `PLL_FUNC_CFG`(0x404) bit31 `DCXO_ST`
= 0 means 40 MHz, and `SEL[26:24]` = 4 in `A27L2_CLK_REG`(0x588) means CPU_PLL.

`N=48 D=2` is the 40 MHz branch of SDK `clock.c:601-627`. An earlier version wrote the
24 MHz set (`N=40 D=1`) unconditionally, which on this 40 MHz board is 1600 MHz —
permanently overclocked.

### R9 — the A27 really did come out of reset

```
  START_ADD readback: 0x83f00000 (want 0x83f00000)
#YWV
```

`#` is the stub's first character; `Y`, `W` and `V` mark `mcache_ctl` written,
`mmisc_ctl` written, and about to jump into OpenSBI. Seeing `#` proves the A27 left
reset and is executing our code — the step that took longest in this whole project,
because FEL's `xfel exec` runs on the E907, and the E907 physically has no Supervisor
mode.

If the `START_ADD` readback does not match, the script stops instead of releasing the
core, because before the cfg reset is deasserted that write is ignored.

### R10 — the kernel reaches S-mode and gets a console

```
A3478
OpenSBI v1.8
Boot HART Base ISA          : rv32imafdcnx
Linux version 7.0.0-rc4-ga0c83177734a-dirty
ttyS0 at MMIO 0x42500000 (irq = 12, base_baud = 12000000) is a 16550A
```

`A3478` is the marker from `head.S` (entered S-mode / cleared sie+sip / wrote
scounteren / before setup_vm / before enabling the MMU), added by
`patches/linux-02-early-uart-markers.patch`. The `ga0c83177734a` in the banner proves
the running kernel is the pinned commit.

(There is no `-rc4-00315-` commit count because `scripts/fetch.sh` shallow-fetches a
single commit, so the tree has no tags and `scripts/setlocalversion`'s `git describe`
falls back to printing only `-g<sha>`. The `-dirty` is because the patches are applied
as working-tree changes rather than committed.)

### R11 — the timer frequency is right

```
TMR_A=4.10
TMR_B=9.16
```

Two reads of `/proc/uptime` with a `sleep 5` between them; the difference must be
close to 5.0. This checks that the dts's `timebase-frequency = <40000000>` matches the
PLMT's real mtime rate. A large discrepancy means that number is wrong.

Without the `andestech,plmt0` node the kernel finds no clocksource, falls back to
`jiffies`, gets no timer tick and hangs at cpuidle with every timestamp reading
`[0.000000]`.

### R12 — boots to an interactive shell

```
>>> V821 rv32 mainline on A27 (S-mode, own OpenSBI via FEL).
/ #

>>> SHELL on A27!
```

About 12 seconds from releasing the core to this point.

### R13 — input round-trip and PLIC interrupts

The board is still alive after `make boot` finishes (felcpux only closes the host-side
serial port), so attach and type:

```
/ # echo hi
hi
/ # cat /proc/interrupts
           CPU0
 10:       1908 RISC-V INTC   5 Edge      riscv-timer
 12:        100 SiFive PLIC   3 Edge      ttyS0
```

`hwirq 3` matches `interrupts-extended = <&plic 3 4>` in the dts.

But `irq = N` in the boot log only proves the DT property was parsed and the PLIC
domain mapped it — **a wrong hwirq prints a non-zero N too**. The decisive evidence is
the count rising as you type, which needs the real wire:

```
ttyS0 interrupt count before typing: 165
after sending some characters:       452     (up 287)
```

This path used to be disabled. The old note about "silent reset on the first
keystroke" was recorded under the **vendor OpenSBI**, the same firmware behind the
62-second deadman, the fid-33 ebreak halt and assorted uncatchable CSR resets. It was
never retested after switching to a self-built OpenSBI master; this run covers it, and
there was no reset at any point during typing.

### R14 — slow-state control run

```sh
make boot-nopll
```

```
  --no-pll: A27 mux back on HOSC (40 MHz)
```

Only the mux moves back to HOSC; the PLL is left alone, so the control run differs
from the normal one by exactly that one setting. It takes ~205 seconds to reach a
shell (normally ~12), hence the 700-second window. Control data only; do not use it
for normal boots.

---

## Known open items

The absolute frequency at `SEL=0` has never been measured. The field table says HOSC,
and if that really is 40 MHz it should be 24x slower than 960 MHz — but the kernel
measures 365x slower, and the factory boot0 timestamps about 1270x slower. That is one
to two orders of magnitude off. The source in that state may not be the 40 MHz DCXO at
all (it could fall back to RC1M), or the slowness may not be purely clock related.
**No register reports the rate the A27 is actually running at**, so this can only be
settled by measurement. It affects none of the other conclusions, so it stays an open
item rather than a guessed number.

Because of that, absolute frequency is always derived rather than measured: `N`/`D`
from `0x4A010000` plus the mux selection from `0x4A010588`, giving 40 MHz x N / D.
