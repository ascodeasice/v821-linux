#!/bin/sh
# 上板前的最後一道 host 端關卡。
#
# 為什麼要有：換 toolchain 之後，有兩種失敗會讓板子完全靜音、而且症狀跟
# 「沒進 FEL」一模一樣，用 power-cycle 去 debug 非常昂貴。這兩種都可以在
# host 上用一行指令抓出來，所以就抓在這裡。
#
# 用法：check-image.sh <CROSS> <KOUT> <BUILD> <FW>
set -e

CROSS=$1; KOUT=$2; BUILD=$3; FW=$4
TOP=$(cd "$(dirname "$0")/.." && pwd)
fail=0
say() { printf '%-46s %s\n' "$1" "$2"; }

echo "== 上板前靜態檢查 =="

# 1. A27 沒有 Zacas / Zabha。
# arch/riscv/Makefile 是看 CONFIG_TOOLCHAIN_HAS_ZACAS/ZABHA（toolchain 有沒有能力），
# 不是看 CONFIG_RISCV_ISA_ZACAS（我們有沒有要用），所以 binutils 2.38 以上會讓
# _zacas_zabha 自動進 -march，gcc 就被授權發 amocas.* 與 byte/halfword 的 amo*.b/.h。
# A27 兩個都沒有，執行到就是沒有 handler 的 illegal instruction。
if [ -f "$KOUT/vmlinux" ]; then
	hits=$("${CROSS}objdump" -d "$KOUT/vmlinux" 2>/dev/null \
	       | grep -cE '\bamocas\.|\bamo(add|and|or|swap|xor|max|min)u?\.(b|h)\b' || true)
	if [ "$hits" -eq 0 ]; then
		say "vmlinux 沒有 Zacas/Zabha 指令" "ok"
	else
		say "vmlinux 沒有 Zacas/Zabha 指令" "找到 $hits 處 — A27 執行到會 illegal instruction"
		"${CROSS}objdump" -d "$KOUT/vmlinux" \
		  | grep -nE '\bamocas\.|\bamo(add|and|or|swap|xor|max|min)u?\.(b|h)\b' | head -10 | sed 's/^/    /'
		fail=1
	fi
else
	say "vmlinux" "找不到 $KOUT/vmlinux"; fail=1
fi

# 2. Image 必須是 rv32
if [ -f "$KOUT/vmlinux" ]; then
	cls=$("${CROSS}readelf" -h "$KOUT/vmlinux" | awk '/Class:/{print $2}')
	[ "$cls" = "ELF32" ] && say "vmlinux 是 ELF32" "ok" \
	                     || { say "vmlinux 是 ELF32" "是 $cls，config 跑掉了"; fail=1; }
fi

# 3. stub 與 golden 相同。這一項同時抓到 PIE、build-id note 與 codegen 漂移
if [ -f "$BUILD/a27_stub.bin" ]; then
	if cmp -s "$BUILD/a27_stub.bin" "$TOP/boot/a27_stub.bin.golden"; then
		say "a27_stub 與 golden 相同" "ok（$(stat -c%s "$BUILD/a27_stub.bin") bytes）"
	else
		say "a27_stub 與 golden 相同" "不同 — 上板前先 objdump -d 對照"
		fail=1
	fi
else
	say "a27_stub.bin" "還沒編"; fail=1
fi

# 4. prebuilt 的 ABI 要跟 dts 宣告的一致。hard-float 的 binary 會在 __sigsetjmp 的 fsd 上 SIGILL
for b in busybox cycfreq; do
	d=$(file -b "$TOP/initramfs/prebuilt/$b" 2>/dev/null || echo missing)
	case "$d" in
	    *"ELF 32-bit"*"RISC-V"*"soft-float"*static*) say "initramfs/prebuilt/$b 是 rv32 soft-float static" "ok" ;;
	    *) say "initramfs/prebuilt/$b 是 rv32 soft-float static" "不對：$d"; fail=1 ;;
	esac
done

# 5. fw_payload 大小合理。太小通常表示 payload 沒包進去
if [ -f "$FW" ]; then
	sz=$(stat -c%s "$FW")
	if [ "$sz" -gt 8000000 ] && [ "$sz" -lt 20000000 ]; then
		say "fw_payload 大小" "ok（$sz bytes）"
	else
		say "fw_payload 大小" "$sz bytes，不在 8-20 MB，payload 可能沒包進去"; fail=1
	fi
else
	say "fw_payload" "找不到 $FW"; fail=1
fi

echo
[ "$fail" -eq 0 ] && echo "靜態檢查通過，可以進 FEL 跑 make boot。" \
                  || { echo "有項目沒過。上面每一項都不需要板子就能修，先修完再上板。"; exit 1; }
