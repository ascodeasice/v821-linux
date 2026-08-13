#!/bin/sh
# 把 linux 與 opensbi 抓到 pins.env 釘住的 commit，然後套上本 repo 的 patch。
#
# 已經抓好而且 HEAD 對得上 pin 的話，這支什麼都不做，可以重複執行。
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
BUILD=${BUILD:-$TOP/build}
. "$TOP/pins.env"

mkdir -p "$BUILD"

# --- 抓到指定 commit ---
# 先試淺層 fetch。GitHub 預設允許 fetch 任何 reachable 的 SHA，但這是 server
# policy 不是 git 保證，所以失敗就退回完整 clone。無論走哪條路，最後都驗 HEAD。
fetch_at() {
	dir=$1; url=$2; sha=$3; name=$4
	if [ -d "$dir/.git" ]; then
		if [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ]; then
			echo "== $name 已經在 $sha"
			return 0
		fi
		echo "== $name 存在但不是釘住的 commit，切過去"
		git -C "$dir" fetch --depth 1 origin "$sha" 2>/dev/null || git -C "$dir" fetch origin
		git -C "$dir" checkout --detach "$sha"
	else
		echo "== 抓 $name $sha"
		mkdir -p "$dir"
		git -C "$dir" init -q
		git -C "$dir" remote add origin "$url" 2>/dev/null || true
		if git -C "$dir" fetch --depth 1 origin "$sha" 2>/dev/null; then
			git -C "$dir" checkout --detach FETCH_HEAD
		else
			echo "   淺層 fetch 不給抓這顆 SHA，退回完整 clone（linux 大約 4 GB）"
			git -C "$dir" fetch origin
			git -C "$dir" checkout --detach "$sha"
		fi
	fi
	got=$(git -C "$dir" rev-parse HEAD)
	[ "$got" = "$sha" ] || { echo "$name HEAD 是 $got，不是釘住的 $sha" >&2; exit 1; }
	echo "   HEAD 驗過：$got"
}

# --- 套 patch ---
# 用 git apply 不是 git am：這些 patch 是純 git diff，沒有 From:/Subject: header，
# git am 會直接 reject。--3way 讓它在 context 有出入時還能靠 blob 資訊接上。
apply_patches() {
	dir=$1; pattern=$2; name=$3
	for p in $pattern; do
		[ -e "$p" ] || continue
		if git -C "$dir" apply --check -R "$p" 2>/dev/null; then
			echo "   已套過，跳過：$(basename "$p")"
			continue
		fi
		echo "   套用：$(basename "$p")"
		git -C "$dir" apply --3way "$p"
	done
	echo "== $name patch 套完"
}

fetch_at "$BUILD/linux"   "$LINUX_URL"   "$LINUX_SHA"   linux
apply_patches "$BUILD/linux" "$TOP/linux-*.patch" linux

fetch_at "$BUILD/opensbi" "$OPENSBI_URL" "$OPENSBI_SHA" opensbi
apply_patches "$BUILD/opensbi" "$TOP/opensbi-*.patch" opensbi

echo
echo "原始碼就緒。接下來：make"
