#!/bin/sh
set -eu

REMOVE_SWAP="false"
DRY_RUN="false"
ASYNC="false"
SUMMARY="true"

while [ "$#" -gt 0 ]; do
	case "$1" in
	--remove-swap)
		REMOVE_SWAP="${2:-false}"
		shift 2
		;;
	--dry-run)
		DRY_RUN="${2:-false}"
		shift 2
		;;
	--async)
		ASYNC="${2:-false}"
		shift 2
		;;
	--summary)
		SUMMARY="${2:-true}"
		shift 2
		;;
	*)
		shift 1
		;;
	esac
done

_sudo() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
		sudo -n "$@"
	else
		"$@"
	fi
}

TARGET_OS="${RUNNER_OS:-$(uname -s 2>/dev/null || echo 'Linux')}"

case "$TARGET_OS" in
Windows* | MINGW* | MSYS* | CYGWIN*)
	echo "::warning::Nix is not supported on Windows. Skipping disk reclaim."
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		{
			printf "initial-free-bytes=0\n"
			printf "final-free-bytes=0\n"
			printf "reclaimed-bytes=0\n"
		} >>"$GITHUB_OUTPUT"
	fi
	exit 0
	;;
esac

get_free_bytes() {
	case "$TARGET_OS" in
	macOS | Darwin)
		if [ -d "/System/Volumes/Data" ]; then
			df -k -P "/System/Volumes/Data" 2>/dev/null | awk 'NR==2 { printf "%.0f\n", $4 * 1024 }' || echo 0
			return
		fi
		;;
	esac
	df -k -P / 2>/dev/null | awk 'NR==2 { printf "%.0f\n", $4 * 1024 }' || echo 0
}

INITIAL_FREE_BYTES=$(get_free_bytes)

# Build candidate purge lists based on OS
CANDIDATES=""

if [ -n "${RECLAIM_CANDIDATES_OVERRIDE:-}" ]; then
	CANDIDATES="$RECLAIM_CANDIDATES_OVERRIDE"
else
	case "$TARGET_OS" in
	Linux*)
		CANDIDATES="/opt/hostedtoolcache
/usr/local/lib/android
/usr/local/share/boost
/usr/share/dotnet
/usr/share/swift
/var/lib/docker
/var/run/docker.sock
/opt/ghc
/usr/local/.ghcup
/opt/google/chrome
/opt/microsoft/msedge
/usr/lib/firefox
/usr/share/man
/usr/share/doc"
		;;
	macOS | Darwin)
		CANDIDATES="/Library/Developer/CoreSimulator
/Users/runner/Library/Android
/Users/runner/hostedtoolcache
/opt/homebrew
/usr/local/Homebrew
/usr/local/share/dotnet
/Users/runner/Library/Caches
/Library/Caches"
		;;
	esac
fi

# Collect existing paths to purge
EXISTING=""
for path in $CANDIDATES; do
	if [ -e "$path" ] || [ -L "$path" ]; then
		EXISTING="${EXISTING}${path}
"
	fi
done

# On macOS, expand Xcode bundles if present (unless overridden)
if [ -z "${RECLAIM_CANDIDATES_OVERRIDE:-}" ]; then
	case "$TARGET_OS" in
	macOS | Darwin)
		for xcode in /Applications/Xcode*.app; do
			if [ -e "$xcode" ]; then
				EXISTING="${EXISTING}${xcode}
"
			fi
		done
		;;
	esac
fi

# Execute unlinking
if [ -n "$EXISTING" ]; then
	if [ "$DRY_RUN" = "true" ]; then
		echo "Nix Reclaim [dry-run]: Found purge targets:"
		echo "$EXISTING" | while IFS= read -r p; do
			[ -z "$p" ] && continue
			echo "  - $p"
		done
	elif [ "$ASYNC" = "true" ]; then
		TRASH_DIR=$(mktemp -d /tmp/.reclaim-trash.XXXXXX 2>/dev/null || mktemp -d -t .reclaim-trash)
		echo "Nix Reclaim: Moving host bloat to staging directory ${TRASH_DIR} for background unlinking..."
		echo "$EXISTING" | while IFS= read -r p; do
			[ -z "$p" ] && continue
			_sudo mv "$p" "$TRASH_DIR/" 2>/dev/null || _sudo rm -rf "$p" >/dev/null 2>&1 || true
		done
		(_sudo rm -rf "$TRASH_DIR" >/dev/null 2>&1 &)
	else
		echo "Nix Reclaim: Purging host bloat in parallel across available CPU cores..."
		for p in $EXISTING; do
			[ -z "$p" ] && continue
			_sudo rm -rf "$p" >/dev/null 2>&1 &
		done
		wait
	fi
fi

# Linux Swap Removal (if enabled)
if [ "$REMOVE_SWAP" = "true" ]; then
	case "$TARGET_OS" in
	Linux*)
		echo "::warning::Disabling swap removes the emergency RAM buffer. Memory-heavy Nix builds may risk OOM."
		if [ "$DRY_RUN" != "true" ]; then
			_sudo swapoff -a 2>/dev/null || true
			_sudo rm -f /swapfile /mnt/swapfile 2>/dev/null || true
		else
			echo "Nix Reclaim [dry-run]: Would run swapoff -a and remove /swapfile /mnt/swapfile"
		fi
		;;
	esac
fi

FINAL_FREE_BYTES=$(get_free_bytes)
RECLAIMED_BYTES=0
if [ "$FINAL_FREE_BYTES" -gt "$INITIAL_FREE_BYTES" ]; then
	RECLAIMED_BYTES=$((FINAL_FREE_BYTES - INITIAL_FREE_BYTES))
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		printf "initial-free-bytes=%s\n" "$INITIAL_FREE_BYTES"
		printf "final-free-bytes=%s\n" "$FINAL_FREE_BYTES"
		printf "reclaimed-bytes=%s\n" "$RECLAIMED_BYTES"
	} >>"$GITHUB_OUTPUT"
fi

if [ "$SUMMARY" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	INIT_GB=$(awk -v b="$INITIAL_FREE_BYTES" 'BEGIN { printf "%.1f", b / 1073741824 }')
	FINAL_GB=$(awk -v b="$FINAL_FREE_BYTES" 'BEGIN { printf "%.1f", b / 1073741824 }')
	REC_GB=$(awk -v b="$RECLAIMED_BYTES" 'BEGIN { printf "%.1f", b / 1073741824 }')

	cat <<EOF >>"$GITHUB_STEP_SUMMARY"
### ❄️ Nix Reclaim: Storage Summary

| Metric | Disk Space |
| :--- | :--- |
| **Initial Free Space** | ${INIT_GB} GB |
| **Reclaimed Space** | **${REC_GB} GB** |
| **Available for Nix** | **${FINAL_GB} GB** |

EOF
fi

echo "Nix Reclaim: Completed. Initial: ${INITIAL_FREE_BYTES} bytes, Final: ${FINAL_FREE_BYTES} bytes, Reclaimed: ${RECLAIMED_BYTES} bytes."
