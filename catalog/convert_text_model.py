#!/usr/bin/env python3
"""The app's on-device text model: MobileCLIP2's text half as Core ML, in the
form MeaningIndex loads (input "tokens" int32 [1, 77], output "embedding",
unit length). Owner, 2026-10-24: "switch to s4" after the search-model test
(catalog/research/2026-10-24-embedding-eval: S4 beat S0 on every measure).

Two files, as with S0's v2/v3:
  --precision fp32   int8 weights, 32-bit compute: the fallback (GPU or CPU)
  --precision ane    int8 weights, 16-bit compute: for the Neural Engine
Check a candidate with catalog/ml_model_gate.py before publishing it with
scripts/publish_ml.sh (which only takes a new model name).

    ~/.venvs/marracat-ml/bin/python catalog/convert_text_model.py --model s4 --precision fp32 --out build/ml/s4-fp32.mlpackage
"""
import argparse
import sys

import numpy as np
import torch
import open_clip
import coremltools as ct

MODELS = {"s0": "MobileCLIP2-S0", "s4": "MobileCLIP2-S4"}
CONTEXT = 77


class TextHalf(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, tokens):
        return self.model.encode_text(tokens.long(), normalize=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=MODELS, required=True)
    ap.add_argument("--precision", choices=["fp32", "ane"], required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    name = MODELS[a.model]
    # S4's text half uses nn.MultiheadAttention, whose eval-mode fast path
    # traces to an op Core ML can't convert; the plain path is the same maths.
    torch.backends.mha.set_fastpath_enabled(False)
    model, _, _ = open_clip.create_model_and_transforms(name, pretrained="dfndr2b")
    model.eval()
    half = TextHalf(model).eval()
    example = open_clip.get_tokenizer(name)(["scented soy candle"]).to(torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(half, example)
        want = half(example).numpy()
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="tokens", shape=(1, CONTEXT), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=ct.precision.FLOAT32 if a.precision == "fp32" else ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
    )
    # Both keep int8 weights (S0's v2 and v3 did too): 32-bit weights would be
    # a ~470 MB download for no measurable gain. Only the compute differs.
    cfg = ct.optimize.coreml.OptimizationConfig(
        global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
    mlmodel = ct.optimize.coreml.linear_quantize_weights(mlmodel, config=cfg)
    mlmodel.short_description = f"{name} text encoder ({a.precision}) for Marracat meaning search"
    mlmodel.save(a.out)
    got = mlmodel.predict({"tokens": example.numpy()})["embedding"].reshape(-1)
    cos = float(np.dot(got, want.reshape(-1)) / np.linalg.norm(got) / np.linalg.norm(want))
    print(f"saved {a.out}: {name} {a.precision}, {got.size} dims, cos vs PyTorch {cos:.5f}")
    return 0 if cos > 0.99 else 1


if __name__ == "__main__":
    sys.exit(main())
