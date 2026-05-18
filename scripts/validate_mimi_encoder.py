#!/usr/bin/env python3
"""Validate Swift MimiEncoder output against Python reference.

Runs Python _encode_audio on a test WAV, saves intermediate tensors at
each stage. The Swift app can then compare its own outputs at each stage
against these reference tensors.

Also produces the final conditioning tensor for direct comparison.

Usage:
    cd /Users/system-backup/dev_local/pocket-tts-macos
    source /Users/system-backup/dev_local/pocket-tts-core-ml-conversion/.venv/bin/activate
    python scripts/validate_mimi_encoder.py [--wav path/to/voice.wav]
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import torch
import safetensors.torch

sys.path.insert(0, str(Path("/Users/system-backup/dev_local/pocket-tts-core-ml-conversion/scripts")))
from load_model import load_tts_model


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wav", default=None, help="WAV file to encode (default: 5s sine wave)")
    parser.add_argument("--output", default="/tmp/mimi_encoder_reference.safetensors")
    args = parser.parse_args()

    print("Loading pocket-tts model...")
    tts = load_tts_model()
    mimi = tts.mimi

    # Load or generate test audio
    if args.wav:
        from pocket_tts.data.audio import audio_read
        from pocket_tts.data.audio_utils import convert_audio
        audio, sr = audio_read(args.wav)
        audio = convert_audio(audio, sr, 24000, 1)
        # Trim to 15s max
        if audio.shape[-1] > 360000:
            audio = audio[..., :360000]
        audio = audio.unsqueeze(0)  # [1, 1, N]
        print(f"Loaded {args.wav}: {audio.shape}")
    else:
        # Generate 5s of 440Hz sine wave at 24kHz
        t = torch.arange(120000, dtype=torch.float32) / 24000.0
        sine = (torch.sin(2 * 3.14159 * 440.0 * t) * 0.5).unsqueeze(0).unsqueeze(0)
        audio = sine
        print(f"Generated 5s sine wave: {audio.shape}")

    # RMS normalize (matches _encode_audio)
    audio_rms = tts._normalize_audio_rms(audio, target_db=-16.0)
    print(f"After RMS norm: mean={audio_rms.mean():.6f}, std={audio_rms.std():.6f}")

    # Step-by-step encode
    from pocket_tts.modules.conv import pad_for_conv1d
    import torch.nn.functional as F

    x = pad_for_conv1d(audio_rms, mimi.frame_size, mimi.frame_size)
    print(f"\n=== After pad_for_conv1d: {x.shape} ===")

    tensors = {"audio_input": audio_rms, "after_pad": x}

    with torch.no_grad():
        # SEANet encoder layers
        for i, layer in enumerate(mimi.encoder.model):
            if hasattr(layer, 'conv') or hasattr(layer, 'block'):
                x = layer(x, None)
            else:
                x = layer(x)
            tensors[f"encoder_layer_{i}"] = x.clone()
            if hasattr(layer, 'conv'):
                print(f"  [{i:2d}] Conv:     {list(x.shape)}, mean={x.mean():.6f}, std={x.std():.6f}")
            elif hasattr(layer, 'block'):
                print(f"  [{i:2d}] ResBlock: {list(x.shape)}, mean={x.mean():.6f}, std={x.std():.6f}")
            else:
                print(f"  [{i:2d}] ELU:      {list(x.shape)}, mean={x.mean():.6f}")

        print(f"\n=== Encoder output: {x.shape} ===")
        tensors["encoder_out"] = x.clone()

        # Encoder transformer
        (x,) = mimi.encoder_transformer(x, None)
        print(f"After transformer: {x.shape}, mean={x.mean():.6f}, std={x.std():.6f}")
        tensors["after_transformer"] = x.clone()

        # Downsample
        x = mimi._to_framerate(x)
        print(f"After downsample: {x.shape}, mean={x.mean():.6f}, std={x.std():.6f}")
        tensors["after_downsample"] = x.clone()

        # Speaker projection
        latents = x.transpose(-1, -2).to(torch.float32)
        conditioning = F.linear(latents, tts.flow_lm.speaker_proj_weight)
        print(f"After speaker_proj: {conditioning.shape}, mean={conditioning.mean():.6f}, std={conditioning.std():.6f}")
        tensors["conditioning"] = conditioning.clone()

    # Save all tensors
    save_dict = {}
    for name, t in tensors.items():
        save_dict[name] = t.contiguous().float().squeeze(0) if t.dim() > 2 else t.contiguous().float()
    safetensors.torch.save_file(save_dict, args.output)
    print(f"\nSaved {len(save_dict)} reference tensors to {args.output}")
    print(f"Final conditioning: shape={list(conditioning.shape)}, mean={conditioning.mean():.6f}, std={conditioning.std():.6f}")


if __name__ == "__main__":
    main()
