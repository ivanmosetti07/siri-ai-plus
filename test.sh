#!/bin/zsh
# Test del motore e dell'app. Una copia temporanea evita i timeout di lettura iCloud durante la compilazione.
set -euo pipefail
cd "$(dirname "$0")"
SCRATCH="${TMPDIR:-/tmp}/siriai-tests"
STAGE="$SCRATCH/source"
mkdir -p "$STAGE"
cp Package.swift "$STAGE/Package.swift"
mkdir -p "$STAGE/Sources" "$STAGE/Tests"
rsync -a --delete Sources/ "$STAGE/Sources/"
rsync -a --delete Tests/ "$STAGE/Tests/"
cd "$STAGE"
export SIRIAI_TEST_DATA_ROOT="$SCRATCH/data"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/clang-cache"
mkdir -p "$SIRIAI_TEST_DATA_ROOT" "$CLANG_MODULE_CACHE_PATH"
SWIFT_TEST_ARGS=()
[[ "${SIRIAI_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]] && SWIFT_TEST_ARGS+=(--disable-sandbox)
swift test --scratch-path "$SCRATCH/build" "${SWIFT_TEST_ARGS[@]}" "$@"
