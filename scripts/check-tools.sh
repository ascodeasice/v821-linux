#!/bin/sh
# Check the host tools and the cross toolchain.
#
# The point is not "is gcc installed" but "can it actually build what we need". The
# critical one is the rv32imafdc / ilp32d freestanding link, which is how OpenSBI is
# linked, and the distro riscv64 toolchain has no such multilib. It works anyway
# because OpenSBI is -nostdlib throughout and does not link libgcc either (rv32's
# 64-bit division comes from lib/utils/libquad). This script turns "it works" into
# evidence instead of an assumption.
set -e

CROSS=${1:-riscv64-linux-gnu-}
CC="${CROSS}gcc"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

say()  { printf '%-46s %s\n' "$1" "$2"; }
need() { if command -v "$1" >/dev/null; then say "$1" "ok"; else say "$1" "missing ($2)"; fail=1; fi; }

echo "== host tools =="
need dtc      "Arch: pacman -S dtc"
need fdtget   "Arch: pacman -S dtc"
need python3  "Arch: pacman -S python"
need git      "Arch: pacman -S git"
need make     "Arch: pacman -S make"
need bison    "needed by the kernel, Arch: pacman -S bison"
need flex     "needed by the kernel, Arch: pacman -S flex"
need bc       "needed by the kernel, Arch: pacman -S bc"
if python3 -c 'import serial' 2>/dev/null; then say "python pyserial" "ok"
else say "python pyserial" "missing (pacman -S python-pyserial)"; fail=1; fi
if command -v xfel >/dev/null; then say xfel "ok"
else say xfel "missing (only make boot needs it, see README)"; fi

echo
echo "== cross toolchain: $CROSS =="
if ! command -v "$CC" >/dev/null; then
	say "$CC" "not found"
	echo
	echo "Arch: sudo pacman -S riscv64-linux-gnu-gcc riscv64-linux-gnu-binutils"
	echo "Or point somewhere else with make CROSS=/abs/path/to/prefix-."
	exit 1
fi
say "$CC" "$($CC -dumpversion)"
say "${CROSS}as" "$(${CROSS}as --version | head -1 | sed 's/.*) //')"

# 1. Kernel path: rv32 codegen + assemble. -c only, no link, so no multilib needed.
printf 'int f(int x){return x+1;}\n' > "$TMP/t.c"
if $CC -march=rv32imac -mabi=ilp32 -mcmodel=medany -mstrict-align -mno-save-restore \
       -c "$TMP/t.c" -o "$TMP/t.o" 2>"$TMP/e1"; then
	say "rv32imac/ilp32 compile (kernel)" "ok"
else
	say "rv32imac/ilp32 compile (kernel)" "failed"; sed 's/^/    /' "$TMP/e1"; fail=1
fi

# 2. OpenSBI path: rv32imafdc_zicsr_zifencei/ilp32d freestanding link.
# The probe source must contain fence.i and csrr: binutils 2.36 moved them out of
# base I into Zifencei / Zicsr, and assembling a bare `j _start` cannot catch that
# (fw_base.S:829 has a fence.i).
printf '.globl _start\n_start: fence.i\n csrr t0, mhartid\n j _start\n' > "$TMP/s.S"
if $CC -march=rv32imafdc_zicsr_zifencei -mabi=ilp32d -mcmodel=medany -nostdlib -fPIE -Wl,-pie \
       -Wl,--no-dynamic-linker -Wl,--build-id=none -o "$TMP/s.elf" "$TMP/s.S" 2>"$TMP/e2"; then
	say "rv32imafdc_zicsr_zifencei/ilp32d link" "ok (OpenSBI will build)"
else
	say "rv32imafdc_zicsr_zifencei/ilp32d link" "failed - OpenSBI will not build"
	sed 's/^/    /' "$TMP/e2"; fail=1
fi

# 3. OpenSBI's own LD_PIE probe (verbatim from its Makefile:195). If this fails,
# OpenSBI aborts with $(error).
if $CC -fPIE -nostdlib -Wl,-pie -x c /dev/null -o /dev/null 2>/dev/null; then
	say "OpenSBI LD_PIE probe" "ok"
else
	say "OpenSBI LD_PIE probe" "failed - OpenSBI Makefile:211 will abort"; fail=1
fi

# 4. Stub path: no-PIE link with -Ttext=
if $CC -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -fno-pie -no-pie \
       -Wl,--build-id=none -Ttext=0x83f00000 -o "$TMP/stub.elf" "$TMP/s.S" 2>"$TMP/e3"; then
	say "stub link (-Ttext, no-pie)" "ok"
else
	say "stub link (-Ttext, no-pie)" "failed"; sed 's/^/    /' "$TMP/e3"; fail=1
fi

echo
echo "== reference info =="
say "multilib" "$($CC -print-multi-lib | tr '\n' ' ')"
if $CC -v 2>&1 | grep -q -- --enable-default-pie; then
	say "default PIE" "yes (so the stub must pass -fno-pie -no-pie)"
else
	say "default PIE" "no"
fi

# 5. Userspace: expected to fail. That failure is the reason prebuilt/ exists.
printf '#include <stdio.h>\nint main(void){puts("hi");return 0;}\n' > "$TMP/u.c"
if $CC -march=rv32imac -mabi=ilp32 -static -o "$TMP/u" "$TMP/u.c" 2>/dev/null; then
	say "rv32 static userspace" "builds (you can rebuild busybox yourself)"
else
	say "rv32 static userspace" "cannot build (expected, see initramfs/prebuilt/README.md)"
fi

echo
[ "$fail" -eq 0 ] && echo "Toolchain check passed." || { echo "Some checks failed, fix the items marked above first."; exit 1; }
