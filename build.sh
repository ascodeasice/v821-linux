#!/bin/sh
# 一鍵建置：檢查工具 -> 抓原始碼並套 patch -> 編 -> 跑上板前的靜態關卡。
#
# 這支不碰板子。跑完之後按 FEL 鈕重插 USB-OTG，再跑 make boot。
#
# 換 toolchain：./build.sh CROSS=/abs/path/to/prefix-
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

make tools "$@"
make src "$@"
make check "$@"

echo
echo "建置完成。接下來："
echo "  1. 按住板子的 FEL 鈕，重插 USB-OTG"
echo "  2. xfel version   # 要看得到 V821"
echo "  3. make boot"
