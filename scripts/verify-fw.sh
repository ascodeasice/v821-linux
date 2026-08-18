#!/bin/sh
# Prove what is actually inside fw_payload.bin before going to the board.
#
# Why this exists: a green make does not mean the right thing was packed. The dtb was
# once packed stale because dtc had not rerun; the board booted normally, just with
# the wrong configuration, with no symptom at all.
# This digs the FDT back out of the firmware blob via the 0xd00dfeed magic and prints
# the properties that affect boot.
#
# Usage: verify-fw.sh <path/to/fw_payload.bin>
set -e

TOP=$(cd "$(dirname "$0")/.." && pwd)
FW=${1:-$TOP/build/fw_payload.bin}

[ -s "$FW" ] || { echo "verify-fw: $FW not found, run make fw first" >&2; exit 1; }
command -v fdtget >/dev/null || { echo "verify-fw: needs fdtget (Arch: pacman -S dtc)" >&2; exit 1; }

OUT=${TMPDIR:-/tmp}/v821-embedded-$$.dtb
trap 'rm -f "$OUT"' EXIT

python3 - "$FW" "$OUT" <<'PY'
import struct, sys
blob = open(sys.argv[1], 'rb').read()
off = blob.find(b'\xd0\x0d\xfe\xed')
if off < 0:
    sys.exit('verify-fw: no FDT magic found in %s' % sys.argv[1])
size = struct.unpack('>I', blob[off + 4:off + 8])[0]
open(sys.argv[2], 'wb').write(blob[off:off + size])
print('FDT at %#x, totalsize=%d' % (off, size))
PY

# riscv,isa should read <not found>: we use the new interface only. If it is present,
# the dts has been reverted to the legacy form.
for p in riscv,isa riscv,isa-base riscv,isa-extensions mmu-type; do
	printf '%-22s %s\n' "$p" "$(fdtget -t s "$OUT" /cpus/cpu@0 "$p" 2>&1)"
done
printf '%-22s %s\n' timebase-frequency "$(fdtget -t u "$OUT" /cpus timebase-frequency 2>&1)"
printf '%-22s %s\n' bootargs "$(fdtget -t s "$OUT" /chosen bootargs 2>&1)"
printf '%-22s %s\n' uart0-status "$(fdtget -t s "$OUT" /soc/serial@42500000 status 2>&1)"
printf '%-22s %s\n' uart0-clock "$(fdtget -t u "$OUT" /soc/serial@42500000 clock-frequency 2>&1)"
printf '%-22s %s\n' plmt "$(fdtget -t s "$OUT" /soc/timer@48400000 compatible 2>&1)"
ls -l "$FW"
