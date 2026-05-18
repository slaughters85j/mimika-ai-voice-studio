#!/usr/bin/env python3
"""Encode a WAV file into Pocket-TTS audio conditioning tensor.

Lightweight sidecar: loads pocket-tts model, runs Mimi encoder + speaker_proj,
saves the conditioning [1, T, 1024] as a safetensors file. No server, no FastAPI.

The macOS app calls this once per voice import. The resulting conditioning
tensor is then fed to voice_prompt_phase.mlpackage (Core ML) to bake the
KV cache in-app.

Usage:
    python encode_voice_conditioning.py --input voice.wav --output conditioning.safetensors
    python encode_voice_conditioning.py --input voice.wav --output conditioning.safetensors --rms-db -16
"""

import argparse
import json
import sys
from pathlib import Path

import torch
import safetensors.torch


def emit(status: str, **kwargs):
    msg = {"status": status, **kwargs}
    print(json.dumps(msg), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="Input WAV file")
    parser.add_argument("--output", required=True, help="Output safetensors file")
    parser.add_argument("--rms-db", type=float, default=-16.0, help="RMS normalization target")
    parser.add_argument("--max-seconds", type=float, default=15.0, help="Max audio duration")
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        emit("error", message=f"Input file not found: {input_path}")
        sys.exit(1)

    emit("loading")

    # Add parent scripts dir to path for load_model
    conversion_scripts = Path(__file__).resolve().parent.parent / "pocket-tts-core-ml-conversion" / "scripts"
    if conversion_scripts.exists():
        sys.path.insert(0, str(conversion_scripts))
    # Also try relative to pocket-tts
    pocket_tts_root = Path(__file__).resolve().parent.parent.parent / "pocket-tts-core-ml-conversion" / "scripts"
    if pocket_tts_root.exists():
        sys.path.insert(0, str(pocket_tts_root))

    from pocket_tts.models.tts_model import TTSModel
    tts = TTSModel.load_model(variant="b6369a24")
    tts.eval()
    for p in tts.parameters():
        p.requires_grad_(False)

    emit("encoding")

    # Load audio
    from pocket_tts.data.audio import audio_read
    from pocket_tts.data.audio_utils import convert_audio

    audio, sr = audio_read(input_path)
    audio = convert_audio(audio, sr, 24000, 1)

    # Trim to max duration
    max_samples = int(args.max_seconds * 24000)
    if audio.shape[-1] > max_samples:
        audio = audio[..., :max_samples]

    with torch.no_grad():
        conditioning = tts._encode_audio(
            audio.unsqueeze(0).to(tts.device),
            target_db=args.rms_db,
        )

    t_frames = conditioning.shape[1]
    emit("saving", t_frames=t_frames)

    safetensors.torch.save_file(
        {"conditioning": conditioning.contiguous().to(torch.float32)},
        args.output,
    )

    size_kb = Path(args.output).stat().st_size / 1024
    emit("done", t_frames=t_frames, size_kb=round(size_kb, 1))


if __name__ == "__main__":
    main()
