#!/bin/sh
# One-shot build: check tools -> fetch sources and apply patches -> build -> run the
# host-side gates.
#
# This never touches the board. When it finishes, hold FEL, replug USB-OTG, then run
# make boot.
#
# To use another toolchain: ./build.sh CROSS=/abs/path/to/prefix-
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

make tools "$@"
make src "$@"
make check "$@"

echo
echo "Build complete. Next:"
echo "  1. Hold the FEL button on the board and replug USB-OTG"
echo "  2. xfel version   # must report V821"
echo "  3. make boot"
