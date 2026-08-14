#!/bin/sh
# 檢查 host 工具與 cross toolchain。
#
# 重點不是「gcc 在不在」，而是「它到底編不編得出我們要的東西」。
# 最關鍵的一項是 rv32imafdc / ilp32d 的 freestanding link——OpenSBI 就是這樣連的，
# 而發行版的 riscv64 toolchain 沒有這組 multilib。它之所以還是能過，是因為
# OpenSBI 全程 -nostdlib、也不連 libgcc（rv32 的 64-bit 除法由 lib/utils/libquad
# 自己提供）。這支就是要把「能過」變成有證據，而不是假設。
set -e

CROSS=${1:-riscv64-linux-gnu-}
CC="${CROSS}gcc"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

say()  { printf '%-46s %s\n' "$1" "$2"; }
need() { if command -v "$1" >/dev/null; then say "$1" "ok"; else say "$1" "缺（$2）"; fail=1; fi; }

echo "== host 工具 =="
need dtc      "Arch: pacman -S dtc"
need fdtget   "Arch: pacman -S dtc"
need python3  "Arch: pacman -S python"
need git      "Arch: pacman -S git"
need make     "Arch: pacman -S make"
need bison    "kernel 需要，Arch: pacman -S bison"
need flex     "kernel 需要，Arch: pacman -S flex"
need bc       "kernel 需要，Arch: pacman -S bc"
if python3 -c 'import serial' 2>/dev/null; then say "python pyserial" "ok"
else say "python pyserial" "缺（pacman -S python-pyserial）"; fail=1; fi
if command -v xfel >/dev/null; then say xfel "ok"
else say xfel "缺（只有 make boot 需要，見 README）"; fi

echo
echo "== cross toolchain：$CROSS =="
if ! command -v "$CC" >/dev/null; then
	say "$CC" "找不到"
	echo
	echo "Arch: sudo pacman -S riscv64-linux-gnu-gcc riscv64-linux-gnu-binutils"
	echo "或用 make CROSS=/abs/path/to/prefix- 指定別的。"
	exit 1
fi
say "$CC" "$($CC -dumpversion)"
say "${CROSS}as" "$(${CROSS}as --version | head -1 | sed 's/.*) //')"

# 1. kernel 路徑：rv32 codegen + assemble。只 -c，不 link，所以不需要 multilib
printf 'int f(int x){return x+1;}\n' > "$TMP/t.c"
if $CC -march=rv32imac -mabi=ilp32 -mcmodel=medany -mstrict-align -mno-save-restore \
       -c "$TMP/t.c" -o "$TMP/t.o" 2>"$TMP/e1"; then
	say "rv32imac/ilp32 編譯（kernel）" "ok"
else
	say "rv32imac/ilp32 編譯（kernel）" "失敗"; sed 's/^/    /' "$TMP/e1"; fail=1
fi

# 2. OpenSBI 路徑：rv32imafdc_zicsr_zifencei/ilp32d 的 freestanding link。
# 探測用的原始碼一定要含 fence.i 與 csrr：binutils 2.36 把它們從 base I 移到
# Zifencei / Zicsr，只組一個 `j _start` 是測不出來的（fw_base.S:829 有 fence.i）。
printf '.globl _start\n_start: fence.i\n csrr t0, mhartid\n j _start\n' > "$TMP/s.S"
if $CC -march=rv32imafdc_zicsr_zifencei -mabi=ilp32d -mcmodel=medany -nostdlib -fPIE -Wl,-pie \
       -Wl,--no-dynamic-linker -Wl,--build-id=none -o "$TMP/s.elf" "$TMP/s.S" 2>"$TMP/e2"; then
	say "rv32imafdc_zicsr_zifencei/ilp32d link" "ok（OpenSBI 可以編）"
else
	say "rv32imafdc_zicsr_zifencei/ilp32d link" "失敗 — OpenSBI 編不起來"
	sed 's/^/    /' "$TMP/e2"; fail=1
fi

# 3. OpenSBI 自己的 LD_PIE 探測（Makefile:195 原文）。它失敗的話 OpenSBI 會直接 $(error)
if $CC -fPIE -nostdlib -Wl,-pie -x c /dev/null -o /dev/null 2>/dev/null; then
	say "OpenSBI LD_PIE 探測" "ok"
else
	say "OpenSBI LD_PIE 探測" "失敗 — OpenSBI Makefile:211 會直接中止"; fail=1
fi

# 4. stub 路徑：-Ttext= 的 no-PIE link
if $CC -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -fno-pie -no-pie \
       -Wl,--build-id=none -Ttext=0x83f00000 -o "$TMP/stub.elf" "$TMP/s.S" 2>"$TMP/e3"; then
	say "stub link（-Ttext, no-pie）" "ok"
else
	say "stub link（-Ttext, no-pie）" "失敗"; sed 's/^/    /' "$TMP/e3"; fail=1
fi

echo
echo "== 參考資訊 =="
say "multilib" "$($CC -print-multi-lib | tr '\n' ' ')"
if $CC -v 2>&1 | grep -q -- --enable-default-pie; then
	say "default PIE" "有（所以 stub 一定要帶 -fno-pie -no-pie）"
else
	say "default PIE" "沒有"
fi

# 5. userspace：預期失敗。失敗才是 prebuilt/ 存在的理由
printf '#include <stdio.h>\nint main(void){puts("hi");return 0;}\n' > "$TMP/u.c"
if $CC -march=rv32imac -mabi=ilp32 -static -o "$TMP/u" "$TMP/u.c" 2>/dev/null; then
	say "rv32 static userspace" "可以編（可以自己重編 busybox）"
else
	say "rv32 static userspace" "編不了（正常，改用 prebuilt/，見 prebuilt/README.md）"
fi

echo
[ "$fail" -eq 0 ] && echo "工具鏈檢查通過。" || { echo "有項目沒過，先處理上面標記的部分。"; exit 1; }
