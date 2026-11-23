#!/bin/bash
# Meaning search's model folder (docs/plans/2026-10-28-meaning-search.md): bge-small-en-v1.5 (BAAI, MIT license) at its
# pinned revision, converted to Core ML at half and full precision, with its vocabulary. Never committed; the probe and
# app builds copy it in, and MeaningTests read it.
#
#   app/Meaning/make_model.sh            the owner's step: downloads about 130 MB from huggingface.co and about 1 GB of
#                                        Python packages, into a throwaway folder deleted after, and writes the folder to
#                                        Application Support › PrepareMe › tools › meaning
#   --to DIR                             write the folder into DIR instead (a session's check)
#   --from DIR                           use model files already downloaded to DIR (checked the same way), no download
#   --python PATH                        use a Python that already has the pinned packages, no install
#
# Each download is checked against its fingerprint, and the conversion is refused unless Core ML's numbers match the
# original model's (meaning.py). The folder is swapped in whole, so a stopped run leaves the old one or none.
set -euo pipefail

REVISION=5c38ec7c405ec4b44b94cc5a9bb96e735b38267a
NAME=bge-small-en-v1.5-5c38ec7
# sha256 of each file at that revision (the Core ML trial's download, 2026-10-28)
FILES=(
    "config.json 094f8e891b932f2000c92cfc663bac4c62069f5d8af5b5278c4306aef3084750"
    "tokenizer.json d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66"
    "model.safetensors 3c9f31665447c8911517620762200d2245a2518d6e7208acc78cd9db317e21ad"
)
# The trial's converter: coremltools 9.0 is tested only up to torch 2.7.0
PACKAGES=(torch==2.7.0 coremltools==9.0 transformers==5.21.0 tokenizers==0.23.3 safetensors==0.8.0 numpy==2.5.4)
UV="$HOME/.venvs/uv/bin/uv"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

to="$HOME/Library/Application Support/PrepareMe/tools/meaning"
from=""
python=""
while [ $# -gt 0 ]; do
    case "$1" in
        --to) to="$2"; shift 2 ;;
        --from) from="$2"; shift 2 ;;
        --python) python="$2"; shift 2 ;;
        *) echo "unknown option $1 (--to DIR, --from DIR, --python PATH)" >&2; exit 2 ;;
    esac
done

work="$(mktemp -d -t prepareme-meaning)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/sources" "$work/out"

for line in "${FILES[@]}"; do
    file=${line%% *}
    want=${line#* }
    if [ -n "$from" ]; then
        cp "$from/$file" "$work/sources/$file"
    else
        curl -fsSL --retry 2 -o "$work/sources/$file" \
            "https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/$REVISION/$file"
    fi
    got=$(shasum -a 256 "$work/sources/$file" | cut -d' ' -f1)
    [ "$got" = "$want" ] || { echo "$file doesn't match its fingerprint; nothing changed." >&2; exit 1; }
done
echo "Model files checked."

if [ -z "$python" ]; then
    "$UV" venv -q --python 3.13 "$work/venv"
    "$UV" pip install -q --python "$work/venv/bin/python" "${PACKAGES[@]}"
    python="$work/venv/bin/python"
fi

"$python" -I "$HERE/meaning.py" convert "$work/sources" "$work/out" \
    "$REPO/app/Meaning/Tests/MeaningSearchTests/Fixtures/meaning"
for precision in fp16 fp32; do
    xcrun coremlcompiler compile "$work/out/bge-small-$precision.mlpackage" "$work/out" >/dev/null
    rm -rf "$work/out/bge-small-$precision.mlpackage"
done
cat > "$work/out/SOURCE.txt" <<EOF
bge-small-en-v1.5 by BAAI, MIT license (https://huggingface.co/BAAI/bge-small-en-v1.5), revision $REVISION.
Converted to Core ML by app/Meaning/make_model.sh on $(date +%Y-%m-%d). Never committed.
EOF

mkdir -p "$to"
rm -rf "$to/$NAME.old"
[ ! -e "$to/$NAME" ] || mv "$to/$NAME" "$to/$NAME.old"
mv "$work/out" "$to/$NAME"
rm -rf "$to/$NAME.old"
echo "Meaning model ready: $to/$NAME"
