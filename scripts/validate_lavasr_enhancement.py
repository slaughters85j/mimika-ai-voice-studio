#!/usr/bin/env python3
"""
LavaSR end-to-end Python reference + per-stage dumps.

Drives the full `LavaEnhance2` pipeline (denoise + BWE + Linkwitz-Riley
merge) for every fixture under
`pocket-tts-macosTests/Fixtures/lavasr_phase10/`, saving the per-stage
intermediates as `.npy` files so the Swift port can assert numerical
parity stage-by-stage.

Per fixture, dumps:

    <name>_denoiser_input_16k.npy        — pre-denoiser 16 kHz mono
    <name>_denoiser_output_16k.npy       — post-denoiser 16 kHz mono
    <name>_bwe_input_48k.npy             — 16 → 48 kHz resampled (post-denoise)
    <name>_bwe_predicted_audio_48k.npy   — Vocos head output BEFORE LR-merge
    <name>_lrmerge_output_48k.npy        — Linkwitz-Riley refined output
    <name>_final_normalized_48k.npy      — RMS-normalized to -16 dB

Plus a per-stage mode where `--per-stage` also dumps the matching
Python intermediates for each ULUNAS sub-module + block so the Swift
port can test in isolation:

    <name>_erb_bm_input.npy
    <name>_erb_bm_output.npy
    <name>_encoder_block_<i>_input.npy
    <name>_encoder_block_<i>_output.npy
    <name>_decoder_block_<i>_input.npy
    <name>_decoder_block_<i>_output.npy
    <name>_dpgrnn_<i>_input.npy
    <name>_dpgrnn_<i>_output.npy
    <name>_xconv_block_input.npy
    <name>_xconv_block_output.npy
    <name>_xdws_block_input.npy
    <name>_xdws_block_output.npy
    <name>_xmb_block_input.npy
    <name>_xmb_block_output.npy

Per-stage outputs land in the same `lavasr_phase10/` fixtures dir so
Swift tests can pick them up via the same path.

Usage:
    cd /Users/system-backup/dev_local/pocket-tts-macos

    # Electron's lavasr-venv has LavaSR + vocos + torch installed:
    /Users/system-backup/Library/Application\\ Support/pocket-tts-electron/lavasr-venv/bin/python \\
        scripts/validate_lavasr_enhancement.py --full

    # Add --per-stage to also dump module/block-level intermediates
    # (needed for Commits 3-5 sub-module parity tests):
    /Users/system-backup/Library/Application\\ Support/pocket-tts-electron/lavasr-venv/bin/python \\
        scripts/validate_lavasr_enhancement.py --full --per-stage

    # Single-fixture mode for spot-checks (legacy):
    /Users/system-backup/Library/Application\\ Support/pocket-tts-electron/lavasr-venv/bin/python \\
        scripts/validate_lavasr_enhancement.py --input <path-to.wav> --output <enhanced.wav>
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Optional

import numpy as np
import soundfile as sf
import torch
import torchaudio.functional as TAF


REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURES_DIR = REPO_ROOT / "pocket-tts-macosTests" / "Fixtures" / "lavasr_phase10"


# ──────────────────────────────────────────────────────────────────────
# RMS normalization (mirrors Python production + Swift VoiceEnhancer)
# ──────────────────────────────────────────────────────────────────────

def rms_normalize(audio: np.ndarray, target_db: float = -16.0) -> np.ndarray:
    """RMS-normalize `audio` to `target_db`, hard-clipped to ±1."""
    rms = float(np.sqrt(np.mean(audio**2)))
    if rms < 1e-8:
        return audio.astype(np.float32)
    target_rms = 10 ** (target_db / 20.0)
    gain = target_rms / rms
    return np.clip(audio * gain, -1.0, 1.0).astype(np.float32)


# ──────────────────────────────────────────────────────────────────────
# Per-stage intermediates (full pipeline dump)
# ──────────────────────────────────────────────────────────────────────

def run_full_pipeline(
    fixture_path: Path,
    *,
    target_db: float = -16.0,
    save_intermediates: bool = True,
    per_stage_dumps: bool = False,
) -> dict[str, np.ndarray]:
    """Run LavaEnhance2 end-to-end with per-stage dumps.

    Mirrors the production `enhance(...)` call but factors the stages
    so we can capture intermediates. Stays bit-equivalent to the
    upstream code: every tensor op matches `LavaEnhance2.enhance()`
    in `LavaSR/model.py` and `LavaBWE.infer()` in
    `LavaSR/enhancer/enhancer.py`.
    """
    from LavaSR.model import LavaEnhance2

    name = fixture_path.stem
    out: dict[str, np.ndarray] = {}

    def dump(stage: str, arr: torch.Tensor | np.ndarray) -> None:
        if isinstance(arr, torch.Tensor):
            arr = arr.detach().cpu().float().numpy()
        flat = arr.squeeze()
        out[stage] = flat
        if save_intermediates:
            np.save(FIXTURES_DIR / f"{name}_{stage}.npy", flat)

    # 1) Load + resample to 16 kHz mono (matches LavaSR.utils.load_wav)
    wav, sr = sf.read(str(fixture_path), dtype="float32")
    if wav.ndim > 1:
        wav = wav.mean(axis=1)
    if sr != 16_000:
        # Match torchaudio's resampler — matches what load_wav uses
        wav_tensor = torch.from_numpy(wav).unsqueeze(0)
        wav_tensor = TAF.resample(wav_tensor, sr, 16_000)
        wav = wav_tensor.squeeze(0).numpy()
    wav_t = torch.from_numpy(wav).float().unsqueeze(0)  # (1, T)
    dump("denoiser_input_16k", wav_t)

    # 2) Bootstrap LavaEnhance2 (downloads weights to ~/.cache/huggingface
    #    on first use, hits cache thereafter)
    print(f"  [{name}] loading LavaEnhance2 from YatharthS/LavaSR ...")
    model = LavaEnhance2("YatharthS/LavaSR", device="cpu")

    # 3) Denoiser (ULUNAS @ 16 kHz)
    print(f"  [{name}] running ULUNAS denoiser ...")
    with torch.inference_mode():
        denoised_16k = model.denoiser_model.infer(wav_t)
    dump("denoiser_output_16k", denoised_16k)

    # 4) Resample 16 → 48 kHz for the BWE
    bwe_input_48k = TAF.resample(denoised_16k, 16_000, 48_000)
    dump("bwe_input_48k", bwe_input_48k)

    # 5) Vocos BWE @ 48 kHz — feature_extractor → backbone → head, but
    #    SKIP the LR-merge step inside `infer()` so we can dump the raw
    #    BWE prediction before the merge.
    print(f"  [{name}] running Vocos BWE ...")
    bwe = model.bwe_model.bwe_model
    with torch.no_grad():
        feats_in = bwe.feature_extractor(bwe_input_48k)
        feats = bwe.backbone(feats_in)
        # `head.forward` is the monkey-patched `custom_forward` from
        # LavaSR/enhancer/enhancer.py — log-mag exp + clip 1e3 + ISTFT
        pred_audio = bwe.head(feats)
    dump("bwe_predicted_audio_48k", pred_audio)

    # 6) FastLRMerge — blend low from input + high from BWE.
    #    The production path constructs lr_refiner inside
    #    `model.load_audio()`:
    #
    #        cutoff = input_sr // 2  # 16000 // 2 = 8000
    #        FastLRMerge(device=..., cutoff=cutoff, transition_bins=1024)
    #
    #    NOT the FastLRMerge() defaults (cutoff=4000, transition=256).
    #    Match the production values here so the dumps reflect what
    #    enhance-voice.py actually produces.
    print(f"  [{name}] running FastLRMerge refiner ...")
    from LavaSR.enhancer.linkwitz_merge import FastLRMerge
    lr_refiner = FastLRMerge(sample_rate=48_000, cutoff=8_000, transition_bins=1024, device="cpu")
    with torch.no_grad():
        a = pred_audio[:, : bwe_input_48k.shape[1]].float()
        b = bwe_input_48k[:, : pred_audio.shape[1]].float()
        merged = lr_refiner(a, b)
    dump("lrmerge_output_48k", merged)

    # 7) RMS-normalize to target
    final = rms_normalize(merged.squeeze().cpu().numpy(), target_db=target_db)
    dump("final_normalized_48k", final)

    # 8) Per-stage module/block dumps (optional, used by Commits 3-5)
    if per_stage_dumps:
        _dump_ulunas_per_stage(model.denoiser_model.model, wav_t, name)

    print(f"  [{name}] done — {len(out)} dumps")
    return out


# ──────────────────────────────────────────────────────────────────────
# Per-module ULUNAS dumps (for Commits 3 & 4 sub-module parity tests)
# ──────────────────────────────────────────────────────────────────────

def _dump_ulunas_per_stage(ulunas, wav_t: torch.Tensor, name: str) -> None:
    """Re-run the ULUNAS forward pass piece-by-piece, dumping every
    sub-module's input and output to disk.

    Side effects (writes to FIXTURES_DIR):
      <name>_erb_bm_input.npy / _output.npy
      <name>_encoder_block_{0..4}_input.npy / _output.npy
      <name>_dpgrnn_{0..1}_input.npy / _output.npy
      <name>_decoder_block_{0..4}_input.npy / _output.npy

      Plus single-shot inputs for the three block types tested in
      isolation (Commit 4):
      <name>_xconv_block_input.npy / _output.npy
      <name>_xdws_block_input.npy / _output.npy
      <name>_xmb_block_input.npy  / _output.npy
    """
    print(f"  [{name}] dumping ULUNAS per-stage intermediates ...")

    def save(stage: str, t: torch.Tensor) -> None:
        np.save(FIXTURES_DIR / f"{name}_{stage}.npy", t.detach().cpu().float().numpy())

    with torch.inference_mode():
        device = wav_t.device
        # Replicate ULUNAS.forward step-by-step (matches the upstream code)
        stft_kwargs = dict(
            n_fft=ulunas.n_fft,
            hop_length=ulunas.hop_len,
            win_length=ulunas.win_len,
            window=torch.hann_window(ulunas.win_len).to(device),
            onesided=True,
        )
        spec = torch.stft(wav_t, **stft_kwargs, return_complex=True)
        spec_ri = torch.view_as_real(spec)  # (B, F, T, 2)
        spec_perm = spec_ri.permute(0, 3, 2, 1)  # (B, 2, T, F)
        feat = torch.log10(torch.norm(spec_perm, dim=1, keepdim=True).clamp(1e-12))

        # ERB band-mux (analysis)
        save("erb_bm_input", feat)
        feat_erb = ulunas.erb.bm(feat)
        save("erb_bm_output", feat_erb)

        # Encoder blocks
        en_outs: list[torch.Tensor] = []
        x = feat_erb
        for i, block in enumerate(ulunas.encoder.en_convs):
            save(f"encoder_block_{i}_input", x)
            x = block(x)
            save(f"encoder_block_{i}_output", x)
            en_outs.append(x)

        # DPGRNN bottleneck
        for i, mod in enumerate(ulunas.dpgrnn):
            save(f"dpgrnn_{i}_input", x)
            x = mod(x)
            save(f"dpgrnn_{i}_output", x)

        # Decoder blocks (uses skip connections from encoder)
        n_blocks = len(ulunas.decoder.de_convs)
        for i, block in enumerate(ulunas.decoder.de_convs):
            inp = x + en_outs[n_blocks - i - 1]
            save(f"decoder_block_{i}_input", inp)
            x = block(inp)
            save(f"decoder_block_{i}_output", x)

        # Block-type single-shot dumps for Commit 4.
        # Use the FIRST block of each type in the encoder:
        #   types=[0,2,1,2,1] → XConvBlock at i=0, XMBBlocks at i=1,
        #                       XDWSBlock at i=2.
        block_inputs = {
            "xconv_block": feat_erb,                   # encoder[0]'s input
            "xmb_block": en_outs[0],                    # encoder[1]'s input
            "xdws_block": en_outs[1],                   # encoder[2]'s input
        }
        for stage, inp in block_inputs.items():
            save(f"{stage}_input", inp)
        # We already saved encoder_block_i_output for i=0,1,2, so the
        # corresponding xconv/xmb/xdws outputs are those — alias them.
        for src_stage, alias_stage in [
            ("encoder_block_0_output", "xconv_block_output"),
            ("encoder_block_1_output", "xmb_block_output"),
            ("encoder_block_2_output", "xdws_block_output"),
        ]:
            np.save(
                FIXTURES_DIR / f"{name}_{alias_stage}.npy",
                np.load(FIXTURES_DIR / f"{name}_{src_stage}.npy"),
            )


# ──────────────────────────────────────────────────────────────────────
# Legacy single-fixture mode (kept for spot-check workflows)
# ──────────────────────────────────────────────────────────────────────

def _legacy_single_fixture(input_path: str, output_path: str) -> None:
    """The pre-Phase-10 single-clip mode: full pipeline + write a WAV."""
    fixture = Path(input_path)
    result = run_full_pipeline(fixture, save_intermediates=False)
    final = result["final_normalized_48k"]
    sf.write(output_path, final, 48_000, subtype="FLOAT")
    print(f"Saved: {output_path}")


# ──────────────────────────────────────────────────────────────────────
# Comparison utility (Python ref vs Swift output)
# ──────────────────────────────────────────────────────────────────────

def _compare(py_path: str, sw_path: str) -> None:
    py_audio, _ = sf.read(py_path)
    sw_audio, _ = sf.read(sw_path)
    n = min(len(py_audio), len(sw_audio))
    py, sw = py_audio[:n], sw_audio[:n]
    diff = py - sw
    print(f"=== Compare: {Path(py_path).name} vs {Path(sw_path).name} ===")
    print(f"Length:       py={len(py_audio)}  sw={len(sw_audio)}  diff={abs(len(py_audio)-len(sw_audio))}")
    print(f"Max |err|:    {np.max(np.abs(diff)):.6f}")
    print(f"Mean |err|:   {np.mean(np.abs(diff)):.6f}")
    print(f"RMS err:      {np.sqrt(np.mean(diff**2)):.6f}")
    if py.std() > 1e-9 and sw.std() > 1e-9:
        corr = float(np.corrcoef(py, sw)[0, 1])
        print(f"Pearson r:    {corr:.6f}")
    sig = float(np.mean(py**2))
    noi = float(np.mean(diff**2))
    if noi > 0:
        print(f"SNR:          {10 * np.log10(sig / noi):.1f} dB")


# ──────────────────────────────────────────────────────────────────────
# Driver
# ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="LavaSR Python reference + per-stage dumps")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--full",
        action="store_true",
        help="Process all fixtures in lavasr_phase10/ and dump per-stage references.",
    )
    mode.add_argument(
        "--input",
        type=str,
        help="Single-fixture mode: input WAV path (legacy spot-check).",
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="Output WAV path (for --input legacy mode).",
    )
    parser.add_argument(
        "--per-stage",
        action="store_true",
        help="In --full mode, also dump ULUNAS module/block-level intermediates.",
    )
    parser.add_argument(
        "--compare",
        nargs=2,
        metavar=("PYREF.wav", "SWOUT.wav"),
        help="Compare two WAVs and print parity metrics.",
    )
    args = parser.parse_args()

    if args.compare:
        _compare(args.compare[0], args.compare[1])
        return 0

    if args.input:
        if not args.output:
            print("error: --output is required with --input", file=sys.stderr)
            return 2
        _legacy_single_fixture(args.input, args.output)
        return 0

    # --full mode
    fixtures = sorted(FIXTURES_DIR.glob("lavasr_fixture_*.wav"))
    if not fixtures:
        print(f"error: no fixtures under {FIXTURES_DIR}", file=sys.stderr)
        print("       run scripts/generate_lavasr_phase10_fixtures.py first", file=sys.stderr)
        return 1
    print(f"Processing {len(fixtures)} fixtures from {FIXTURES_DIR}")
    for fx in fixtures:
        run_full_pipeline(fx, per_stage_dumps=args.per_stage)

    # Summary
    npy_files = sorted(FIXTURES_DIR.glob("*.npy"))
    print()
    print(f"=== Done — {len(npy_files)} .npy intermediate files written ===")
    for f in npy_files:
        arr = np.load(f, mmap_mode="r")
        print(f"  {f.name:60s} shape={arr.shape}  dtype={arr.dtype}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
