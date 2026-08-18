#!/bin/sh
# Regenerate config/v821_rv32_defconfig and config/config-diff.txt.
#
# Both are `make savedefconfig` output, i.e. the minimal expression relative to the
# Kconfig defaults, so the diff between them is exactly the decisions we made.
# Running scripts/diffconfig on the raw .config instead gives 4000+ lines, almost all
# of it cascaded removals from switching off NET / IIO / DRM and friends.
#
# Usage: config-diff.sh <LINUX> <KOUT> <BUILD> <CROSS> <TOP>
set -e

LINUX=$1; KOUT=$2; BUILD=$3; CROSS=$4; TOP=$5
KMAKE="make -C $LINUX ARCH=riscv CROSS_COMPILE=$CROSS"

echo "== generating a defconfig from the current .config =="
$KMAKE O="$KOUT" savedefconfig >/dev/null

# CONFIG_INITRAMFS_SOURCE is an absolute path and has to be stripped from both
# artifacts, otherwise the repo records the directory name of whichever machine
# produced them.
grep -v '^CONFIG_INITRAMFS_SOURCE=' "$KOUT/defconfig" > "$BUILD/defconfig.stripped"

{
	echo "# V821 (Allwinner sun300iw1p1) RV32 minimal bring-up."
	echo "# Generated from the .config verified on hardware with \`make savedefconfig\`."
	echo "# CONFIG_INITRAMFS_SOURCE is deliberately absent: it is an absolute path, and"
	echo "# the Makefile injects \$(BUILD)/initramfs.list at build time via scripts/config."
	cat "$BUILD/defconfig.stripped"
} > "$TOP/config/v821_rv32_defconfig"
echo "   wrote config/v821_rv32_defconfig ($(grep -c '' "$TOP/config/v821_rv32_defconfig") lines)"

echo "== generating the upstream rv32_defconfig baseline =="
rm -rf "$BUILD/kbase"
$KMAKE O="$BUILD/kbase" rv32_defconfig >/dev/null
$KMAKE O="$BUILD/kbase" savedefconfig >/dev/null

{
	cat <<'EOF'
# V821 RV32 kernel config: what differs from the upstream rv32_defconfig
#
# Both sides are `make savedefconfig` output, expressed relative to the Kconfig
# defaults, so this diff is the decisions we actually made, with no cascaded noise.
#
# Regenerate: make config-diff
#
EOF
	# --label keeps file paths and mtimes out of the output; otherwise every
	# regeneration shows a fake difference.
	diff -u --label a/rv32_defconfig --label b/v821_rv32_defconfig \
	     "$BUILD/kbase/defconfig" "$BUILD/defconfig.stripped" || true
} > "$TOP/config/config-diff.txt"
echo "   wrote config/config-diff.txt ($(grep -c '' "$TOP/config/config-diff.txt") lines)"

echo
echo "Top-level switches we turned off:"
grep '^+# CONFIG_' "$TOP/config/config-diff.txt" | sed 's/^+/  /'
