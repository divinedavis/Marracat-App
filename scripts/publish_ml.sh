#!/usr/bin/env bash
# Publish the app's on-device AI files to marracat.com/ml/ (served by nginx
# from /var/www/marracat-catalog/ml): the product meaning vectors from
# catalog/embed_products.py --publish and, when given, the MobileCLIP text
# model as an Apple Archive of its compiled .mlmodelc.
#
#   scripts/publish_ml.sh                                         # vectors only
#   scripts/publish_ml.sh path/to/Model.mlpackage mobileclip-text-v4.aar   # + a NEW model
#
# A model is published under a new name only, never over an existing one:
# installed apps fall back to mobileclip-text-v2.aar (S0) or -v4.aar (S4), with
# v3 / v5 on the Neural Engine, so replacing a file in place could break them.
# Run catalog/ml_model_gate.py on the candidate first.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${CATALOG_HOST_SSH:-root@167.71.170.219}"
DEST=/var/www/marracat-catalog/ml
# Two spaces since 2026-10-24: S0's vectors (v1) for app builds that still run
# S0's text model, S4's (v2) for builds from then on (MeaningIndex.vectorsURL).
# A file whose embeddings are missing is skipped, not published stale.
PUBLISH=()
for pair in "catalog/.cache/embeddings/product-vectors.bin:product-vectors-v1.bin:512" \
            "catalog/.cache/embeddings-s4/product-vectors.bin:product-vectors-v2.bin:768"; do
  IFS=: read -r SRC NAME MODEL_DIMS <<<"$pair"
  [[ -s "$SRC" ]] || { echo "skip $NAME: $SRC missing (catalog/embed_products.py --publish)"; continue; }
  python3 - "$SRC" "$MODEL_DIMS" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read(20)
assert d[:4] == b"MRV1", "not a vectors file"
version, dims, model_dims, count = struct.unpack("<IIII", d[4:20])
assert version in (1, 2) and dims == 256 and model_dims == int(sys.argv[2]) and count > 50000, (version, dims, model_dims, count)
print(f"vectors: {count} products, {dims} dims from {model_dims}")
PY
  PUBLISH+=("$SRC:$NAME")
done
(( ${#PUBLISH[@]} )) || { echo "error: no vectors to publish" >&2; exit 1; }
ssh "$HOST" "install -d -m 755 $DEST"
for pair in "${PUBLISH[@]}"; do
  IFS=: read -r SRC NAME <<<"$pair"
  scp -q "$SRC" "$HOST:$DEST/$NAME.tmp"
  ssh "$HOST" "mv $DEST/$NAME.tmp $DEST/$NAME && chmod 644 $DEST/$NAME"
done
if [[ $# -ge 1 ]]; then
  NAME="${2:?usage: publish_ml.sh Model.mlpackage mobileclip-text-vN.aar}"
  [[ "$NAME" =~ ^mobileclip-text-v[0-9]+\.aar$ ]] || { echo "error: name must look like mobileclip-text-vN.aar" >&2; exit 1; }
  if ssh "$HOST" "test -e $DEST/$NAME"; then echo "error: $NAME already published; pick a new version" >&2; exit 1; fi
  WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
  xcrun coremlcompiler compile "$1" "$WORK" >/dev/null
  mv "$WORK"/*.mlmodelc "$WORK/MobileCLIPText.mlmodelc"
  aa archive -d "$WORK" -subdir MobileCLIPText.mlmodelc -o "$WORK/model.aar"
  scp -q "$WORK/model.aar" "$HOST:$DEST/$NAME.tmp"
  ssh "$HOST" "mv -n $DEST/$NAME.tmp $DEST/$NAME && chmod 644 $DEST/$NAME"
  echo "model: $(du -h "$WORK/model.aar" | cut -f1)"
fi
for f in product-vectors-v1.bin product-vectors-v2.bin $( [[ $# -ge 1 ]] && echo "$2" ); do
  # A report, not a gate: a file not published yet (S4's v2 on its first night,
  # 2026-10-25) must not fail the nightly run.
  { curl -sfI "https://marracat.com/ml/$f" | grep -i -E "^(HTTP|content-length)" | tr -d '\r' | tr '\n' ' '; } || printf '%s not on the server yet' "$f"; echo
done
