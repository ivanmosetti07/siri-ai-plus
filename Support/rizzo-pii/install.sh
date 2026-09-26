#!/bin/zsh
# Prepara il motore di anonimizzazione di Siri AI+ (rizzo-pii di Rizzo AI Academy, licenza MIT).
# Una volta sola, o per aggiornare il modello: scarica il modello da Hugging Face, lo converte in Core ML e lo mette in
# ~/Library/Application Support/Siri AI+/Models/rizzo-pii/. Python serve solo qui: Siri AI+ usa Core ML e Swift.
#
# Uso: Support/rizzo-pii/install.sh [revisione]      (predefinita v1.5.0, quella verificata con il banco di prova)
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
REVISION="${1:-v1.5.0}"
WORK="${TMPDIR:-/tmp}/rizzo-pii-install"
DEST="$HOME/Library/Application Support/Siri AI+/Models/rizzo-pii"
mkdir -p "$WORK" "$DEST"
cd "$WORK"

# Python 3.12 isolato (coremltools non ha ancora le versioni per Python 3.14), senza toccare Homebrew.
if [[ ! -x venv/bin/python ]]; then
  pipx run uv venv --python 3.12 venv
  pipx run uv pip install --python venv/bin/python "torch==2.7.0" "transformers==4.57.6" "coremltools==9.0" safetensors huggingface_hub numpy
fi

echo "Scarico rizzoaiacademy/rizzo-pii-0.3B ($REVISION)…"
venv/bin/python - "$REVISION" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download("rizzoaiacademy/rizzo-pii-0.3B", revision=sys.argv[1], local_dir="model", allow_patterns=["*.json", "*.safetensors"])
PY

echo "Converto in Core ML…"
venv/bin/python "$HERE/convert.py" model coreml
rm -rf compiled && mkdir compiled
xcrun coremlcompiler compile coreml/RizzoPII.mlpackage compiled/ >/dev/null

rm -rf "$DEST/RizzoPII.mlmodelc"
cp -R compiled/RizzoPII.mlmodelc "$DEST/"
cp coreml/tokenizer.json coreml/config.json "$DEST/"
printf '{"model":"rizzoaiacademy/rizzo-pii-0.3B","revision":"%s","license":"MIT","converted":"%s","precision":"fp16","shapes":[64,128,256,512]}\n' \
  "$REVISION" "$(date +%F)" > "$DEST/info.json"
echo "✅ Motore installato in $DEST ($(du -sh "$DEST" | cut -f1))"
echo "   Verifica: bin/siriai --anonimizza \"Mario Rossi, CF RSSMRA85H12F205Y\""
echo "   Parità con l'originale: git clone https://github.com/Rizzo-AI-Academy/rizzo-pii \"$WORK/rizzo-pii\" && \\"
echo "     $WORK/venv/bin/python $HERE/reference.py \"$WORK/rizzo-pii\" \"$WORK/model\" \"$WORK/reference.json\" && \\"
echo "     bin/siriai --anonimizza-prova \"$WORK/reference.json\" cpu"
