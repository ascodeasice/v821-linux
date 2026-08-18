#!/bin/sh
# 證明 fw_payload.bin 裡面到底包了什麼，上板前先驗。
#
# 為什麼需要：make 綠燈不等於包對。dtb 曾經因為 dtc 沒重跑而包了舊的一顆進去，
# 板子照常開機、只是跑錯設定，完全沒有徵兆（見 claude-report.md §23）。
# 這支從 firmware blob 裡面用 0xd00dfeed magic 把 FDT 挖回來，印出會影響開機的屬性。
#
# 用法：verify-fw.sh <path/to/fw_payload.bin>
set -e

TOP=$(cd "$(dirname "$0")/.." && pwd)
FW=${1:-$TOP/build/fw_payload.bin}

[ -s "$FW" ] || { echo "verify-fw: 找不到 $FW，先跑 make fw" >&2; exit 1; }
command -v fdtget >/dev/null || { echo "verify-fw: 需要 fdtget（Arch: pacman -S dtc）" >&2; exit 1; }

OUT=${TMPDIR:-/tmp}/v821-embedded-$$.dtb
trap 'rm -f "$OUT"' EXIT

python3 - "$FW" "$OUT" <<'PY'
import struct, sys
blob = open(sys.argv[1], 'rb').read()
off = blob.find(b'\xd0\x0d\xfe\xed')
if off < 0:
    sys.exit('verify-fw: %s 裡面找不到 FDT magic' % sys.argv[1])
size = struct.unpack('>I', blob[off + 4:off + 8])[0]
open(sys.argv[2], 'wb').write(blob[off:off + size])
print('FDT 位於 %#x，totalsize=%d' % (off, size))
PY

# riscv,isa 應該是 <not found>：我們只用新介面。它若存在表示 dts 被改回 legacy 了。
for p in riscv,isa riscv,isa-base riscv,isa-extensions mmu-type; do
	printf '%-22s %s\n' "$p" "$(fdtget -t s "$OUT" /cpus/cpu@0 "$p" 2>&1)"
done
printf '%-22s %s\n' timebase-frequency "$(fdtget -t u "$OUT" /cpus timebase-frequency 2>&1)"
printf '%-22s %s\n' bootargs "$(fdtget -t s "$OUT" /chosen bootargs 2>&1)"
printf '%-22s %s\n' uart0-status "$(fdtget -t s "$OUT" /soc/serial@42500000 status 2>&1)"
printf '%-22s %s\n' uart0-clock "$(fdtget -t u "$OUT" /soc/serial@42500000 clock-frequency 2>&1)"
printf '%-22s %s\n' plmt "$(fdtget -t s "$OUT" /soc/timer@48400000 compatible 2>&1)"
ls -l "$FW"
