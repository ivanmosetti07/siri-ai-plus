#!/bin/zsh
# Compila la CLI (bin/siriai) e l'app desktop («Siri AI+.app»).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

# Compilazione da una copia locale: iCloud può bloccare anche la lettura dei sorgenti Swift.
SCRATCH="${TMPDIR:-/tmp}/siriai-build"
SOURCE="$SCRATCH/source"
mkdir -p "$SOURCE/Sources" "$SOURCE/Tests" "$SOURCE/Support" "$SOURCE/Siri AI+.xcodeproj"
cp Package.swift "$SOURCE/Package.swift"
rsync -a --delete Sources/ "$SOURCE/Sources/"
rsync -a --delete Tests/ "$SOURCE/Tests/"
cp Support/App-Info.plist "$SOURCE/Support/App-Info.plist"
rsync -a --delete "Siri AI+.xcodeproj/" "$SOURCE/Siri AI+.xcodeproj/"
cd "$SOURCE"
SWIFT_BUILD_ARGS=()
[[ "${SIRIAI_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]] && SWIFT_BUILD_ARGS+=(--disable-sandbox)
[[ "${SIRIAI_NO_DSYM:-0}" == "1" ]] && SWIFT_BUILD_ARGS+=(-debug-info-format none)
swift build -c release --product SiriAI --scratch-path "$SCRATCH/build" "${SWIFT_BUILD_ARGS[@]}" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/Support/Info.plist"
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH/build" "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$SCRATCH/clang-cache}" xcodebuild \
  -project "Siri AI+.xcodeproj" -scheme "Siri AI+" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$SCRATCH/xcode-derived" \
  -clonedSourcePackagesDirPath "$SCRATCH/xcode-packages" -packageCachePath "$SCRATCH/xcode-cache" \
  CODE_SIGNING_ALLOWED=NO build
BUILT_APP="$SCRATCH/xcode-derived/Build/Products/Release/Siri AI+.app"
[[ -d "$BUILT_APP" ]] || { echo "L'app Xcode non è stata prodotta: $BUILT_APP" >&2; exit 1; }
cd "$ROOT"

# Firma con un certificato stabile: con la firma "ad hoc" ogni build è un'app nuova per macOS
# e i permessi (Calendario, Promemoria, Automazione) verrebbero richiesti di nuovo.
# SIGN_IDENTITY sceglie il certificato. App Intents richiede un Team ID:
# se disponibile, preferisci una firma Apple a un certificato locale senza Team ID.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"(Apple Development:|Developer ID Application:|Apple Distribution:)/ {print $2; exit}')"
  [[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/{print $2; exit}')"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
[[ "$SIGN_IDENTITY" == "-" ]] && echo "⚠️  Nessun certificato di firma: uso la firma ad hoc (macOS richiederà i permessi a ogni build)."

# CLI: firma lontano da iCloud; il binario finito sarà copiato nel progetto alla fine.
STAGED_CLI="$SCRATCH/siriai-cli"
cp "$BIN_DIR/SiriAI" "$STAGED_CLI"
xattr -c "$STAGED_CLI" 2>/dev/null || true
codesign --force --sign "$SIGN_IDENTITY" --identifier com.ivanmosetti.siriaiplus.cli "$STAGED_CLI"

# App nativa Xcode: conserva i metadati App Intents che Comandi Rapidi legge dal bundle.
# Assemblata e firmata fuori da Documenti (iCloud aggiunge attributi durante la firma), poi copiata qui.
FINAL="Siri AI+.app"
APP="$SCRATCH/stage/Siri AI+.app"
rm -rf "$SCRATCH/stage"
mkdir -p "$SCRATCH/stage"
ditto "$BUILT_APP" "$APP"
mkdir -p "$APP/Contents/Resources"
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
APP_TEAM_ID="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ -n "$APP_TEAM_ID" && "$APP_TEAM_ID" != "not set" ]] || echo "⚠️  Firma senza Team ID: Comandi Rapidi può mostrare le azioni ma non eseguirle."
# Aggiornamento sul posto (file sostituiti uno per uno) invece di cancellare e ricreare il bundle:
# iCloud, vedendo sparire e ricomparire la cartella, creava copie in conflitto («Siri AI+ 2.app»…).
mkdir -p "$FINAL"
rsync -a --delete "$APP/" "$FINAL/"
FINAL_VERIFIED=1
if ! codesign --verify --deep --strict "$FINAL" >/dev/null 2>&1; then
  FINAL_VERIFIED=0
  echo "⚠️  Il bundle nella cartella iCloud non supera la verifica della firma: usa lo ZIP verificato qui sotto."
fi
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
if [[ "$FINAL_VERIFIED" == "1" ]]; then
  echo "✅ App: ./$FINAL"
fi
echo "✅ ZIP verificato: ./Siri AI+.zip  (espandi e sposta l'app in /Applications/)"

# ./build.sh --valuta: dopo la build, il banco di prova delle risposte (qualche minuto, usa il modello del Mac).
if [[ " $* " == *" --valuta "* ]]; then
  ./bin/siriai --eval Support/eval/qualita.json
  SIRIAI_PLAN_ONLY=1 ./bin/siriai --eval Support/eval/pianificatore.json
  ./bin/siriai --eval Support/eval/documenti.json
  SIRIAI_PLAN_ONLY=1 ./bin/siriai --eval Support/eval/strumenti.json
fi
