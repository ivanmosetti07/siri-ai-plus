#!/bin/zsh
# Compila la CLI (bin/siriai) e l'app desktop («Siri AI+.app»).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

# Compilazione da una copia locale: iCloud può bloccare anche la lettura dei sorgenti Swift.
SCRATCH="${TMPDIR:-/tmp}/siriai-build"
SOURCE="$SCRATCH/source"
mkdir -p "$SOURCE/Sources" "$SOURCE/Tests"
cp Package.swift "$SOURCE/Package.swift"
rsync -a --delete Sources/ "$SOURCE/Sources/"
rsync -a --delete Tests/ "$SOURCE/Tests/"
cd "$SOURCE"
SWIFT_BUILD_ARGS=()
[[ "${SIRIAI_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]] && SWIFT_BUILD_ARGS+=(--disable-sandbox)
[[ "${SIRIAI_NO_DSYM:-0}" == "1" ]] && SWIFT_BUILD_ARGS+=(-debug-info-format none)
swift build -c release --scratch-path "$SCRATCH/build" "${SWIFT_BUILD_ARGS[@]}" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/Support/Info.plist"
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH/build" "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
cd "$ROOT"

# Firma con un certificato stabile: con la firma "ad hoc" ogni build è un'app nuova per macOS
# e i permessi (Calendario, Promemoria, Automazione) verrebbero richiesti di nuovo.
# SIGN_IDENTITY sceglie il certificato; altrimenti il primo valido per la firma del codice.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/{print $2; exit}')}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
[[ "$SIGN_IDENTITY" == "-" ]] && echo "⚠️  Nessun certificato di firma: uso la firma ad hoc (macOS richiederà i permessi a ogni build)."

# CLI: firma lontano da iCloud; il binario finito sarà copiato nel progetto alla fine.
STAGED_CLI="$SCRATCH/siriai-cli"
cp "$BIN_DIR/SiriAI" "$STAGED_CLI"
xattr -c "$STAGED_CLI" 2>/dev/null || true
codesign --force --sign "$SIGN_IDENTITY" --identifier com.ivanmosetti.siriaiplus.cli "$STAGED_CLI"

# App: bundle .app con Info.plist e icona.
# Assemblata e firmata fuori da Documenti (iCloud aggiunge attributi durante la firma), poi copiata qui.
FINAL="Siri AI+.app"
APP="$SCRATCH/stage/Siri AI+.app"
rm -rf "$SCRATCH/stage"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SiriAIApp" "$APP/Contents/MacOS/SiriAIPlus"
cp Support/App-Info.plist "$APP/Contents/Info.plist"
[[ -f Support/AppIcon.icns ]] || swift Support/make_icon.swift Support/AppIcon.icns
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# La CLI dentro l'app: fa da ponte MCP perché ChatGPT e Gemini possano usare gli strumenti.
mkdir -p "$APP/Contents/Helpers"
cp "$STAGED_CLI" "$APP/Contents/Helpers/siriai"
# L'entitlement PCC è gestito da Apple: si incorpora solo con un profilo che lo autorizza.
PCC_PROFILE="${PCC_PROFILE:-}"
if [[ -n "$PCC_PROFILE" ]]; then
  [[ "$SIGN_IDENTITY" != "-" ]] || { echo "PCC richiede un'identità di firma valida." >&2; exit 1; }
  [[ -f "$PCC_PROFILE" ]] || { echo "Profilo PCC non trovato: $PCC_PROFILE" >&2; exit 1; }
  security cms -D -i "$PCC_PROFILE" > "$SCRATCH/pcc-profile.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.private-cloud-compute' "$SCRATCH/pcc-profile.plist" 2>/dev/null)" == "true" ]] \
    || { echo "Il profilo non autorizza Private Cloud Compute." >&2; exit 1; }
  cp "$PCC_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi
# iCloud e il Finder aggiungono attributi estesi che codesign rifiuta.
xattr -cr "$APP"
if [[ -n "$PCC_PROFILE" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ROOT/Support/PrivateCloudCompute.entitlements" "$APP"
else
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
fi
# Aggiornamento sul posto (file sostituiti uno per uno) invece di cancellare e ricreare il bundle:
# iCloud, vedendo sparire e ricomparire la cartella, creava copie in conflitto («Siri AI+ 2.app»…).
mkdir -p "$FINAL"
rsync -a --delete "$APP/" "$FINAL/"
codesign -v "$FINAL" || echo "⚠️  iCloud ha aggiunto attributi al bundle: usa lo ZIP verificato qui sotto."
ARCHIVE="$SCRATCH/Siri AI+.zip"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
ditto --noextattr "$ARCHIVE" "Siri AI+.zip"
VERIFY="$SCRATCH/verifica-zip"
rm -rf "$VERIFY"
mkdir -p "$VERIFY"
ditto -x -k "Siri AI+.zip" "$VERIFY"
codesign --verify --deep --strict "$VERIFY/Siri AI+.app"
mkdir -p bin
ditto --noextattr "$STAGED_CLI" bin/siriai.new
mv -f bin/siriai.new bin/siriai
codesign -v bin/siriai

echo "✅ CLI: ./bin/siriai"
echo "✅ App: ./$FINAL  (per installarla: cp -R \"$FINAL\" /Applications/)"
echo "✅ ZIP verificato: ./Siri AI+.zip  (espandi e sposta l'app in /Applications/)"

# ./build.sh --valuta: dopo la build, il banco di prova delle risposte (qualche minuto, usa il modello del Mac).
if [[ " $* " == *" --valuta "* ]]; then
  ./bin/siriai --eval Support/eval/qualita.json
  SIRIAI_PLAN_ONLY=1 ./bin/siriai --eval Support/eval/pianificatore.json
  ./bin/siriai --eval Support/eval/documenti.json
  SIRIAI_PLAN_ONLY=1 ./bin/siriai --eval Support/eval/strumenti.json
fi
