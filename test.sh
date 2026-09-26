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
swift test --scratch-path "$SCRATCH/build" "$@"
