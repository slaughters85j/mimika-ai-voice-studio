#!/usr/bin/env python3
"""
Convert the LavaSR ULUNAS denoiser weights from PyTorch to safetensors.

Downloads `YatharthS/LavaSR/denoiser/denoiser.bin` from HuggingFace,
unpacks the state dict, and saves a `.safetensors` file MLX-Swift can
load via `MLX.loadArrays(url:)`. Output ~800 KB (same as the input;
no precision change).

Output location (gitignored — regenerable from this script):
    pocket-tts-macosTests/Fixtures/lavasr_phase10/lavasr_denoiser.safetensors

Usage:
    cd /Users/system-backup/dev_local/pocket-tts-macos
    /Users/system-backup/Library/Application\\ Support/pocket-tts-electron/lavasr-venv/bin/python \\
        scripts/export_lavasr_denoiser_weights.py

For Commit 9 (publish): the same file uploads to
`slaughters85j/pocket-tts-voice-tools` as part of the voice-tools
bundle. The HF object's SHA256 will be baked into
`BundledMLModel.voiceTools.expectedSHA256`.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import torch
import safetensors.torch
from huggingface_hub import hf_hub_download


REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURES_DIR = REPO_ROOT / "pocket-tts-macosTests" / "Fixtures" / "lavasr_phase10"
OUT_PATH = FIXTURES_DIR / "lavasr_denoiser.safetensors"


def main() -> int:
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)

    print("Downloading YatharthS/LavaSR/denoiser/denoiser.bin from HuggingFace...")
    src = hf_hub_download("YatharthS/LavaSR", "denoiser/denoiser.bin")
    src_size = Path(src).stat().st_size
    print(f"  cached at {src} ({src_size / 1024:.1f} KB)")

    print("Loading PyTorch state dict...")
    state = torch.load(src, map_location="cpu", weights_only=True)
    print(f"  {len(state)} tensors")

    # Cast everything to float32 — denoiser weights are already fp32,
    # but normalize the dtype so MLX-Swift can load without questions.
    fp32_state = {k: v.float().contiguous() for k, v in state.items()}

    print(f"Saving safetensors to {OUT_PATH} ...")
    safetensors.torch.save_file(fp32_state, str(OUT_PATH))
    out_size = OUT_PATH.stat().st_size
    print(f"  wrote {out_size / 1024:.1f} KB")

    # Compute SHA256 so the Commit 9 manifest can quote it.
    with OUT_PATH.open("rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    print(f"  SHA256: {sha}")

    # Print a sample of the weight keys + shapes so the Swift port has
    # a reference of what the state dict looks like.
    print("\nWeight keys (first 30):")
    for k in sorted(fp32_state.keys())[:30]:
        v = fp32_state[k]
        print(f"  {k:60s} {list(v.shape)}  {v.dtype}")
    if len(fp32_state) > 30:
        print(f"  ... and {len(fp32_state) - 30} more")
    print(f"\nTotal: {len(fp32_state)} tensors, "
          f"{sum(v.numel() for v in fp32_state.values()):,} parameters")
    return 0


if __name__ == "__main__":
    sys.exit(main())
