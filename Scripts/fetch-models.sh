#!/bin/bash
#
# Downloads the speaker-diarization model Cheerio bundles.
#
# Run once after cloning:
#     ./Scripts/fetch-models.sh
#
# The model is not committed — it's ~93 MB, which would bloat every clone of the
# repo forever. It IS bundled into the built app: nothing may need the network
# while recording a meeting, and Cheerio has no networking code at all, so the
# model must already be on disk. This script is the build-time half of that
# arrangement.
#
# Model: NVIDIA Sortformer v2.1, 6-bit palettized, converted to Core ML by
# FluidInference. Licensed CC BY 4.0 — redistribution is fine as long as the
# attribution in THIRD-PARTY-NOTICES.md travels with it (the app bundles it).
# Source: https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml
#
set -euo pipefail

REPO="FluidInference/diar-streaming-sortformer-coreml"
REVISION="main"
REMOTE_DIR="v3/palettized/Sortformer_v2.1.mlmodelc"
MODEL_NAME="Sortformer_v2.1.mlmodelc"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_ROOT="${SCRIPT_DIR}/../Cheerio/Resources/Models"
DEST="${DEST_ROOT}/${MODEL_NAME}"

# sha256  relative-path — pinned so a changed upstream file is a hard failure
# rather than a silently different model.
read -r -d '' MANIFEST <<'EOF' || true
2906b22a79f1d41870fbc9ed0348c9103b06a4794653b6bb0a609bfcd44217b9  analytics/coremldata.bin
96db957cd3c8bb35c1127b2405c360e0e5d2e3a7808b30692f1fb55fd6062719  coremldata.bin
5a8281049b2a65a3be541cfd9f949e84b8fe1c5251ce90e46da1626fed54e58a  model0/analytics/coremldata.bin
c392b563ce501ebe841e1ff7d8a4ff659ee72cdaa6784e16114739feaa37aecc  model0/coremldata.bin
f6b9b011973f566a8037664418abd87c3c878c2b5bcfaa86d4eceebcfba6b4df  model0/model.mil
88a98803e35186b1dfb41d7f748f7cee5093bb6efeb117f56953c17549792fa4  model0/weights/0-weight.bin
5a8281049b2a65a3be541cfd9f949e84b8fe1c5251ce90e46da1626fed54e58a  model1/analytics/coremldata.bin
93887e1d6f29e366d58f88efc4caa3b35e189a960db6f91bae3ea5721e3c825d  model1/coremldata.bin
9b14e85cb0bf274ab646242d9dfbe84ef61cc6956b4d0b203a3fbebc74b40383  model1/model.mil
ebc39adbaef1d895b0c6f432b5480425fecdfac139fb232ddb21d0dd76b923a8  model1/weights/1-weight.bin
EOF

checksum_of() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

# Already complete and intact? Then this is a no-op, so it's safe to run from a
# build phase.
if [ -d "$DEST" ]; then
    intact=1
    while read -r expected path; do
        [ -n "$expected" ] || continue
        if [ ! -f "${DEST}/${path}" ] || [ "$(checksum_of "${DEST}/${path}")" != "$expected" ]; then
            intact=0
            break
        fi
    done <<< "$MANIFEST"
    if [ "$intact" -eq 1 ]; then
        echo "✓ ${MODEL_NAME} already present and verified"
        exit 0
    fi
    echo "Existing model is incomplete or modified — re-downloading"
    rm -rf "$DEST"
fi

echo "Downloading ${MODEL_NAME} (~93 MB) from ${REPO}"
mkdir -p "$DEST"

failed=0
while read -r expected path; do
    [ -n "$expected" ] || continue
    url="https://huggingface.co/${REPO}/resolve/${REVISION}/${REMOTE_DIR}/${path}"
    mkdir -p "$(dirname "${DEST}/${path}")"
    printf '  %s ... ' "$path"
    if ! curl -sSfL "$url" -o "${DEST}/${path}"; then
        echo "DOWNLOAD FAILED"
        failed=1
        break
    fi
    actual="$(checksum_of "${DEST}/${path}")"
    if [ "$actual" != "$expected" ]; then
        echo "CHECKSUM MISMATCH"
        echo "      expected $expected"
        echo "      actual   $actual"
        failed=1
        break
    fi
    echo "ok"
done <<< "$MANIFEST"

if [ "$failed" -ne 0 ]; then
    # Never leave a half-written model behind — a partial .mlmodelc fails at
    # runtime in a much more confusing way than a missing one.
    rm -rf "$DEST"
    echo "✗ Download failed; nothing was left in ${DEST_ROOT}" >&2
    exit 1
fi

echo "✓ ${MODEL_NAME} → ${DEST}"
