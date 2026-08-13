#!/bin/sh
# 重產 v821_rv32_defconfig 與 config-diff.txt。
#
# 兩份都是 `make savedefconfig` 的輸出，也就是相對於 Kconfig 預設值的最小表述，
# 所以 diff 出來就是我們真正做的決定。直接對 .config 跑 scripts/diffconfig 會得到
# 四千多行，其中絕大多數是關掉 NET / IIO / DRM 等上層開關之後的連鎖移除。
#
# 用法：config-diff.sh <LINUX> <KOUT> <BUILD> <CROSS> <TOP>
set -e

LINUX=$1; KOUT=$2; BUILD=$3; CROSS=$4; TOP=$5
KMAKE="make -C $LINUX ARCH=riscv CROSS_COMPILE=$CROSS"

echo "== 從目前的 .config 產 defconfig =="
$KMAKE O="$KOUT" savedefconfig >/dev/null

# CONFIG_INITRAMFS_SOURCE 是絕對路徑，兩個產物都要把它拿掉，否則 repo 裡會出現
# 產生它的那台機器的目錄名。
grep -v '^CONFIG_INITRAMFS_SOURCE=' "$KOUT/defconfig" > "$BUILD/defconfig.stripped"

{
	echo "# V821 (Allwinner sun300iw1p1) RV32 minimal bring-up."
	echo "# 從已驗證開機的 .config 用 \`make savedefconfig\` 產生。"
	echo "# CONFIG_INITRAMFS_SOURCE 刻意不寫在這裡：它是絕對路徑，由 Makefile 在 build 時"
	echo "# 用 scripts/config 注入 \$(BUILD)/initramfs.list。"
	cat "$BUILD/defconfig.stripped"
} > "$TOP/v821_rv32_defconfig"
echo "   寫入 v821_rv32_defconfig（$(grep -c '' "$TOP/v821_rv32_defconfig") 行）"

echo "== 產上游 rv32_defconfig 的 baseline =="
rm -rf "$BUILD/kbase"
$KMAKE O="$BUILD/kbase" rv32_defconfig >/dev/null
$KMAKE O="$BUILD/kbase" savedefconfig >/dev/null

{
	cat <<'EOF'
# V821 RV32 kernel config：與上游 rv32_defconfig 的差異
#
# 兩邊都是 `make savedefconfig` 的輸出，相對於 Kconfig 預設值，所以這份 diff
# 就是我們真正做的決定，沒有連鎖產生的雜訊。
#
# 重新產生：make config-diff
#
EOF
	# --label 是為了不要把檔案路徑與 mtime 寫進去，否則每次重產都會有假的差異
	diff -u --label a/rv32_defconfig --label b/v821_rv32_defconfig \
	     "$BUILD/kbase/defconfig" "$BUILD/defconfig.stripped" || true
} > "$TOP/config-diff.txt"
echo "   寫入 config-diff.txt（$(grep -c '' "$TOP/config-diff.txt") 行）"

echo
echo "我們主動關掉的上層開關："
grep '^+# CONFIG_' "$TOP/config-diff.txt" | sed 's/^+/  /'
