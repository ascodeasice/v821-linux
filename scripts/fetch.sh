#!/bin/sh
# Fetch linux and opensbi at the commits pinned in pins.env, then apply this repo's
# patches.
#
# If they are already fetched and HEAD matches the pin, this does nothing, so it is
# safe to run repeatedly.
set -e

TOP=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD:-$TOP/build}
. "$TOP/pins.env"

mkdir -p "$BUILD"

# --- fetch at a given commit ---
# Try a shallow fetch first. GitHub allows fetching any reachable SHA by default, but
# that is server policy rather than a git guarantee, so fall back to a full clone on
# failure. Either way, HEAD is verified at the end.
fetch_at() {
	dir=$1; url=$2; sha=$3; name=$4
	if [ -d "$dir/.git" ]; then
		if [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ]; then
			echo "== $name already at $sha"
			return 0
		fi
		echo "== $name exists but is not the pinned commit, checking it out"
		git -C "$dir" fetch --depth 1 origin "$sha" 2>/dev/null || git -C "$dir" fetch origin
		git -C "$dir" checkout --detach "$sha"
	else
		echo "== fetching $name $sha"
		mkdir -p "$dir"
		git -C "$dir" init -q
		git -C "$dir" remote add origin "$url" 2>/dev/null || true
		if git -C "$dir" fetch --depth 1 origin "$sha" 2>/dev/null; then
			git -C "$dir" checkout --detach FETCH_HEAD
		else
			echo "   shallow fetch of that SHA refused, falling back to a full clone (linux is ~4 GB)"
			git -C "$dir" fetch origin
			git -C "$dir" checkout --detach "$sha"
		fi
	fi
	got=$(git -C "$dir" rev-parse HEAD)
	[ "$got" = "$sha" ] || { echo "$name HEAD is $got, not the pinned $sha" >&2; exit 1; }
	echo "   HEAD verified: $got"
}

# --- apply patches ---
# git apply, not git am: these are plain git diffs with no From:/Subject: header, and
# git am rejects them outright. --3way lets it reattach via blob info when the context
# has drifted.
apply_patches() {
	dir=$1; pattern=$2; name=$3
	for p in $pattern; do
		[ -e "$p" ] || continue
		if git -C "$dir" apply --check -R "$p" 2>/dev/null; then
			echo "   already applied, skipping: $(basename "$p")"
			continue
		fi
		echo "   applying: $(basename "$p")"
		git -C "$dir" apply --3way "$p"
	done
	echo "== $name patches applied"
}

fetch_at "$BUILD/linux"   "$LINUX_URL"   "$LINUX_SHA"   linux
apply_patches "$BUILD/linux" "$TOP/patches/linux-*.patch" linux

fetch_at "$BUILD/opensbi" "$OPENSBI_URL" "$OPENSBI_SHA" opensbi
apply_patches "$BUILD/opensbi" "$TOP/patches/opensbi-*.patch" opensbi

echo
echo "Sources ready. Next: make"
