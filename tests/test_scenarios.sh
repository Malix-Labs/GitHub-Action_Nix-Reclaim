#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
RECLAIM_SH="${SCRIPT_DIR}/src/reclaim.sh"

FAILED=0
TOTAL=0

assert_eq() {
	TOTAL=$((TOTAL + 1))
	expected="$1"
	actual="$2"
	description="$3"
	if [ "$expected" = "$actual" ]; then
		echo "  ✅ PASS: $description"
	else
		echo "  ❌ FAIL: $description (Expected '$expected', got '$actual')"
		FAILED=$((FAILED + 1))
	fi
}

assert_file_not_exists() {
	TOTAL=$((TOTAL + 1))
	target="$1"
	description="$2"
	if [ ! -e "$target" ]; then
		echo "  ✅ PASS: $description"
	else
		echo "  ❌ FAIL: $description (Target still exists: '$target')"
		FAILED=$((FAILED + 1))
	fi
}

assert_match() {
	TOTAL=$((TOTAL + 1))
	pattern="$1"
	target_file="$2"
	description="$3"
	if grep -q "$pattern" "$target_file" 2>/dev/null; then
		echo "  ✅ PASS: $description"
	else
		echo "  ❌ FAIL: $description (Pattern '$pattern' not found in $target_file)"
		FAILED=$((FAILED + 1))
	fi
}

echo "=== Running Nix-Reclaim Test Suite ==="

# -----------------------------------------------------------------------------
# Test 1: Windows runner skip and zero outputs
# -----------------------------------------------------------------------------
echo "[Test 1] Windows runner detection & skip"
TEST_TMP=$(mktemp -d)
OUT_FILE="${TEST_TMP}/github_output"
touch "$OUT_FILE"

RUNNER_OS="Windows" GITHUB_OUTPUT="$OUT_FILE" sh "$RECLAIM_SH" >"${TEST_TMP}/stdout" 2>&1
assert_match "^initial-free-bytes=0$" "$OUT_FILE" "Windows initial-free-bytes is 0"
assert_match "^final-free-bytes=0$" "$OUT_FILE" "Windows final-free-bytes is 0"
assert_match "^reclaimed-bytes=0$" "$OUT_FILE" "Windows reclaimed-bytes is 0"
assert_match "Nix is not supported on Windows" "${TEST_TMP}/stdout" "Warning message output for Windows"
rm -rf "$TEST_TMP"

# -----------------------------------------------------------------------------
# Test 2: Dry-run execution outputs and summary
# -----------------------------------------------------------------------------
echo "[Test 2] Dry-run execution"
TEST_TMP=$(mktemp -d)
OUT_FILE="${TEST_TMP}/github_output"
SUM_FILE="${TEST_TMP}/github_summary"
touch "$OUT_FILE" "$SUM_FILE"

GITHUB_OUTPUT="$OUT_FILE" GITHUB_STEP_SUMMARY="$SUM_FILE" \
	sh "$RECLAIM_SH" --dry-run true >"${TEST_TMP}/stdout" 2>&1

assert_match "^initial-free-bytes=[0-9]\+" "$OUT_FILE" "Outputs initial-free-bytes as integer"
assert_match "^final-free-bytes=[0-9]\+" "$OUT_FILE" "Outputs final-free-bytes as integer"
assert_match "^reclaimed-bytes=[0-9]\+" "$OUT_FILE" "Outputs reclaimed-bytes as integer"
assert_match "Nix Reclaim: Storage Summary" "$SUM_FILE" "Summary header generated"
assert_match "Available for Nix" "$SUM_FILE" "Summary metrics table generated"
rm -rf "$TEST_TMP"

# -----------------------------------------------------------------------------
# Test 3: Synchronous unlinking of candidate paths
# -----------------------------------------------------------------------------
echo "[Test 3] Synchronous parallel unlinking"
TEST_TMP=$(mktemp -d)
MOCK_DIR1="${TEST_TMP}/mock_bloat_1"
MOCK_DIR2="${TEST_TMP}/mock_bloat_2"
mkdir -p "${MOCK_DIR1}/subdir" "${MOCK_DIR2}"
echo "sample file 1" >"${MOCK_DIR1}/file.bin"
echo "sample file 2" >"${MOCK_DIR2}/large.bin"

CANDIDATES="${MOCK_DIR1}
${MOCK_DIR2}"

RECLAIM_CANDIDATES_OVERRIDE="$CANDIDATES" \
	sh "$RECLAIM_SH" --dry-run false --summary false --nix-permissions false >"${TEST_TMP}/stdout" 2>&1

assert_file_not_exists "$MOCK_DIR1" "Mock directory 1 unlinked"
assert_file_not_exists "$MOCK_DIR2" "Mock directory 2 unlinked"
rm -rf "$TEST_TMP"

# -----------------------------------------------------------------------------
# Test 4: Async background unlinking
# -----------------------------------------------------------------------------
echo "[Test 4] Asynchronous background unlinking"
TEST_TMP=$(mktemp -d)
MOCK_DIR3="${TEST_TMP}/mock_bloat_3"
mkdir -p "${MOCK_DIR3}/nested"
echo "async payload" >"${MOCK_DIR3}/nested/data.bin"

RECLAIM_CANDIDATES_OVERRIDE="$MOCK_DIR3" \
	sh "$RECLAIM_SH" --async true --dry-run false --summary false --nix-permissions false >"${TEST_TMP}/stdout" 2>&1

# In async mode, the original path is unlinked/moved immediately
assert_file_not_exists "$MOCK_DIR3" "Mock directory 3 unlinked immediately in async mode"
rm -rf "$TEST_TMP"

# -----------------------------------------------------------------------------
# Test 5: Summary disabled (--summary false)
# -----------------------------------------------------------------------------
echo "[Test 5] Summary flag disabled"
TEST_TMP=$(mktemp -d)
OUT_FILE="${TEST_TMP}/github_output"
SUM_FILE="${TEST_TMP}/github_summary"
touch "$OUT_FILE" "$SUM_FILE"

GITHUB_OUTPUT="$OUT_FILE" GITHUB_STEP_SUMMARY="$SUM_FILE" \
	sh "$RECLAIM_SH" --dry-run true --summary false >/dev/null 2>&1

if [ ! -s "$SUM_FILE" ]; then
	assert_eq "empty" "empty" "Summary file remains untouched when summary=false"
else
	assert_eq "empty" "non-empty" "Summary file was written when summary=false"
fi
rm -rf "$TEST_TMP"

# -----------------------------------------------------------------------------
# Test 6: Dry-run swapoff flag handling
# -----------------------------------------------------------------------------
echo "[Test 6] Swap removal flag handling in dry-run mode"
TEST_TMP=$(mktemp -d)
sh "$RECLAIM_SH" --dry-run true --remove-swap true >"${TEST_TMP}/stdout" 2>&1
assert_match "Disabling swap removes the emergency RAM buffer" "${TEST_TMP}/stdout" "Warning emitted for swap removal"
assert_match "Would run swapoff -a" "${TEST_TMP}/stdout" "Dry-run noted swap removal without executing"
rm -rf "$TEST_TMP"

# -----------------------------------------------------------------------------
# Test 7: Action.yml structural validation
# -----------------------------------------------------------------------------
echo "[Test 7] action.yml structural verification"
ACTION_YML="${SCRIPT_DIR}/action.yml"
assert_match 'name: "GitHub Action - Nix Reclaim"' "$ACTION_YML" "action.yml has valid name"
assert_match "using: composite" "$ACTION_YML" "action.yml is composite action"
assert_match "Malix-Labs/GitHub-Action_Runner-Fetch@v1.1.0" "$ACTION_YML" "action.yml pins Runner-Fetch@v1.1.0"
assert_match 'scope-level: "1"' "$ACTION_YML" "action.yml configures scope-level 1"

echo "========================================"
echo "Results: Total: $TOTAL, Failed: $FAILED"
echo "========================================"

if [ "$FAILED" -ne 0 ]; then
	exit 1
fi
