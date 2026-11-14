#!/usr/bin/env python3
"""The Shop by style prompts' meaning vectors, made once on the Mac
(2026-10-18) so the app's style boards need only the product vectors: Home
no longer loads the 61 MB text model at launch to embed ten fixed sentences.

Reads each ShopStyle prompt from Marracat/ML/MeaningFeatures.swift, runs
MobileCLIP2-S4's text half (the model the app runs since 2026-10-24, open_clip "dfndr2b"),
and writes Marracat/ML/style-prompts.json: each style's prompt and its
unit-length 512-d embedding (float32, little-endian, base64), the same raw
output the app's model gives before centring. The app uses a vector only
while its prompt text matches, so editing a prompt without rerunning this
falls back to embedding it on the phone.

Self-check: the app's probe phrase must land where the app's v2 model puts
it (MeaningIndex.probeReference, cosine >= 0.995), or nothing is written.

    ~/.venvs/marracat-ml/bin/python catalog/embed_style_prompts.py
"""
import base64
import json
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FEATURES = ROOT / "Marracat/ML/MeaningFeatures.swift"
INDEX = ROOT / "Marracat/ML/MeaningIndex.swift"
OUT = ROOT / "Marracat/ML/style-prompts.json"


def prompts(swift: str) -> list[tuple[str, str]]:
    found = re.findall(r'\.init\(id: "([^"]+)",.*?prompt: "([^"]+)"\)', swift)
    if not found:
        sys.exit("no ShopStyle prompts found in MeaningFeatures.swift")
    return found


def probe(swift: str) -> tuple[str, list[float]]:
    phrase = re.search(r'static let probePhrase = "([^"]+)"', swift).group(1)
    b64 = re.search(r'probeReference: \[Float\] = \{\s*let data = Data\(base64Encoded: "([^"]+)"', swift).group(1)
    raw = base64.b64decode(b64)
    return phrase, list(struct.unpack(f"<{len(raw) // 4}f", raw))


def main():
    import numpy as np
    import open_clip
    import torch

    styles = prompts(FEATURES.read_text())
    phrase, reference = probe(INDEX.read_text())
    model, _, _ = open_clip.create_model_and_transforms("MobileCLIP2-S4", pretrained="dfndr2b")
    tok = open_clip.get_tokenizer("MobileCLIP2-S4")
    model.eval()
    with torch.no_grad():
        e = model.encode_text(tok([phrase] + [p for _, p in styles])).float().numpy()
    e /= np.linalg.norm(e, axis=1, keepdims=True)
    agreement = float(e[0] @ np.array(reference, dtype=np.float32))
    print(f"probe '{phrase}': cosine {agreement:.4f} with the app's reference")
    if agreement < 0.995:
        sys.exit("the Mac's model doesn't match the app's; nothing written")
    out = {"model": "MobileCLIP2-S4 dfndr2b", "styles": [
        {"id": sid, "prompt": text, "embedding": base64.b64encode(e[i + 1].astype("<f4").tobytes()).decode()}
        for i, (sid, text) in enumerate(styles)]}
    OUT.write_text(json.dumps(out, indent=1) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}: {len(styles)} styles")


if __name__ == "__main__":
    main()
