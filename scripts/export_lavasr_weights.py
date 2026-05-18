#!/usr/bin/env python3
"""
Export LavaSR v2 enhancer weights to safetensors for mlx-swift.
Run from the pocket-tts venv (which has LavaSR installed).

Usage:
    cd /Users/system-backup/dev_local/pocket-tts-macos
    source /Users/system-backup/dev_local/pocket-tts/.venv/bin/activate
    python scripts/export_lavasr_weights.py
"""

import json
from pathlib import Path

import torch
import safetensors.torch
from huggingface_hub import hf_hub_download

def main():
    out_dir = Path("pocket-tts-macos/Resources/lavasr")
    out_dir.mkdir(parents=True, exist_ok=True)

    # Download enhancer v2 weights from HuggingFace
    print("Downloading LavaSR enhancer v2 weights...")
    model_path = hf_hub_download("YatharthS/LavaSR", "enhancer_v2/pytorch_model.bin")
    config_path = hf_hub_download("YatharthS/LavaSR", "enhancer_v2/config.yaml")

    state_dict = torch.load(model_path, map_location="cpu", weights_only=True)
    print(f"Loaded {len(state_dict)} weight tensors")

    # Convert to fp32 safetensors
    fp32_dict = {k: v.float() for k, v in state_dict.items()}
    out_path = out_dir / "lavasr_enhancer_v2.safetensors"
    safetensors.torch.save_file(fp32_dict, str(out_path))
    print(f"Saved to {out_path} ({out_path.stat().st_size / 1e6:.1f} MB)")

    # Copy config
    import shutil
    shutil.copy(config_path, out_dir / "config.yaml")
    print(f"Config copied to {out_dir / 'config.yaml'}")

    # Print key summary for mlx-swift port
    print("\nWeight keys:")
    for k, v in sorted(state_dict.items()):
        print(f"  {k}: {list(v.shape)} {v.dtype}")

if __name__ == "__main__":
    main()
