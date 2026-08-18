#!/bin/sh
# The last host-side gate before going to the board.
#
# Why it exists: after a toolchain change, two kinds of failure leave the board
# completely silent with symptoms identical to "never entered FEL", and debugging
# those by power-cycling is expensive. Both are catchable on the host with one
# command, so they are caught here.
#
# Usage: check-image.sh <CROSS> <KOUT> <BUILD> <FW>
set -e

CROSS=$1; KOUT=$2; BUILD=$3; FW=$4
TOP=$(cd "$(dirname "$0")/.." && pwd)
fail=0
say() { printf '%-46s %s\n' "$1" "$2"; }

echo "== static checks before flashing =="

# 1. The A27 has neither Zacas nor Zabha.
# arch/riscv/Makefile keys off CONFIG_TOOLCHAIN_HAS_ZACAS/ZABHA (what the toolchain
# can do), not CONFIG_RISCV_ISA_ZACAS (what we asked for), so binutils 2.38+ lets
# _zacas_zabha into -march and authorises gcc to emit amocas.* and byte/halfword
# amo*.b/.h. The A27 has neither, and hitting one is an illegal instruction with no
# handler.
if [ -f "$KOUT/vmlinux" ]; then
	hits=$("${CROSS}objdump" -d "$KOUT/vmlinux" 2>/dev/null \
	       | grep -cE '\bamocas\.|\bamo(add|and|or|swap|xor|max|min)u?\.(b|h)\b' || true)
	if [ "$hits" -eq 0 ]; then
		say "vmlinux free of Zacas/Zabha instructions" "ok"
	else
		say "vmlinux free of Zacas/Zabha instructions" "$hits found - illegal instruction on the A27"
		"${CROSS}objdump" -d "$KOUT/vmlinux" \
		  | grep -nE '\bamocas\.|\bamo(add|and|or|swap|xor|max|min)u?\.(b|h)\b' | head -10 | sed 's/^/    /'
		fail=1
	fi
else
	say "vmlinux" "$KOUT/vmlinux not found"; fail=1
fi

# 2. The Image must be rv32
if [ -f "$KOUT/vmlinux" ]; then
	cls=$("${CROSS}readelf" -h "$KOUT/vmlinux" | awk '/Class:/{print $2}')
	[ "$cls" = "ELF32" ] && say "vmlinux is ELF32" "ok" \
	                     || { say "vmlinux is ELF32" "got $cls, the config has drifted"; fail=1; }
fi

# 3. Stub matches golden. This one check catches PIE, the build-id note, and codegen
# drift at the same time.
if [ -f "$BUILD/a27_stub.bin" ]; then
	if cmp -s "$BUILD/a27_stub.bin" "$TOP/boot/a27_stub.bin.golden"; then
		say "a27_stub matches golden" "ok ($(stat -c%s "$BUILD/a27_stub.bin") bytes)"
	else
		say "a27_stub matches golden" "differs - diff objdump -d before flashing"
		fail=1
	fi
else
	say "a27_stub.bin" "not built yet"; fail=1
fi

# 4. The prebuilt ABI must match what the dts declares. A hard-float binary SIGILLs
# on the fsd in __sigsetjmp.
for b in busybox; do
	d=$(file -b "$TOP/initramfs/prebuilt/$b" 2>/dev/null || echo missing)
	case "$d" in
	    *"ELF 32-bit"*"RISC-V"*"soft-float"*static*) say "initramfs/prebuilt/$b is rv32 soft-float static" "ok" ;;
	    *) say "initramfs/prebuilt/$b is rv32 soft-float static" "wrong: $d"; fail=1 ;;
	esac
done

# 5. fw_payload size is plausible. Too small usually means the payload was not packed.
if [ -f "$FW" ]; then
	sz=$(stat -c%s "$FW")
	if [ "$sz" -gt 8000000 ] && [ "$sz" -lt 20000000 ]; then
		say "fw_payload size" "ok ($sz bytes)"
	else
		say "fw_payload size" "$sz bytes, outside 8-20 MB, the payload may be missing"; fail=1
	fi
else
	say "fw_payload" "$FW not found"; fail=1
fi

echo
[ "$fail" -eq 0 ] && echo "Static checks passed. Enter FEL and run make boot." \
                  || { echo "Some checks failed. Every one of them is fixable without the board - fix them first."; exit 1; }
