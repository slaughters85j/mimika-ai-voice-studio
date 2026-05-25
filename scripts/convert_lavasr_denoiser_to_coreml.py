#!/usr/bin/env python3
"""
Convert the LavaSR ULUNAS denoiser from PyTorch to Core ML.

Phase 10b / Commit 1 — the conversion spike. If this produces a
loadable `lavasr_denoiser.mlpackage` that round-trips audio with
Pearson ≥ 0.98 vs the PyTorch reference, we ditch the manual MLX-Swift
port path and ship the Core ML artifact instead.

Strategy: wrap ULUNAS to bake in a fixed input/output length (bypasses
the dynamic-pad `aten::Int` bug in coremltools 9.0 + torch 2.10),
trace, then convert directly via coremltools (no ONNX intermediate —
coremltools 9.0 deprecated that path).

Usage:
    cd /Users/system-backup/dev_local/pocket-tts-macos
    /Users/system-backup/Library/Application\\ Support/pocket-tts-electron/lavasr-venv/bin/python \\
        scripts/convert_lavasr_denoiser_to_coreml.py

Outputs:
    pocket-tts-macosTests/Fixtures/lavasr_phase10/lavasr_denoiser.mlpackage
    pocket-tts-macosTests/Fixtures/lavasr_phase10/lavasr_denoiser_golden_*.npy
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import torch


REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURES_DIR = REPO_ROOT / "pocket-tts-macosTests" / "Fixtures" / "lavasr_phase10"

# Fixed I/O shape for the Core ML model.
INPUT_LENGTH_SAMPLES = 128_000  # 8 s @ 16 kHz
INPUT_SAMPLE_RATE = 16_000


class ULUNASExport(torch.nn.Module):
    """Wrapper that outputs the MASKED COMPLEX SPECTROGRAM rather than
    audio. The Swift side runs the iSTFT to reconstruct audio.
    Splitting the graph at this point sidesteps two coremltools 9.0
    issues:
      1. `torch.istft` has no MIL converter yet (NotImplementedError).
      2. Dynamic-shape pad in the original `ULUNAS.forward` trips an
         `aten::Int` lowering bug.
    Both are bypassed by stopping at the masked spectrogram.

    Output shape: `(B, F, T, 2)` where the last dim is [real, imag].
    For our fixed input (1, 128000) @ 16 kHz with n_fft=512, hop=256:
       F = n_fft/2 + 1 = 257
       T = 1 + 128000/256 = 501  (center=True default)
    Output is (1, 257, 501, 2).
    """

    def __init__(self, denoiser: torch.nn.Module):
        super().__init__()
        self.denoiser = denoiser

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        d = self.denoiser
        device = x.device
        stft_kwargs = dict(
            n_fft=d.n_fft,
            hop_length=d.hop_len,
            win_length=d.win_len,
            window=torch.hann_window(d.win_len).to(device),
            onesided=True,
        )

        # ---- Replicate ULUNAS.forward up to the masked spectrogram ----
        spec = torch.stft(x, **stft_kwargs, return_complex=True)
        spec_ri = torch.view_as_real(spec)         # (B, F, T, 2)
        spec_p = spec_ri.permute(0, 3, 2, 1)        # (B, 2, T, F)
        feat = torch.log10(torch.norm(spec_p, dim=1, keepdim=True).clamp(1e-12))

        feat = d.erb.bm(feat)                       # (B, 1, T, 129)
        feat, en_outs = d.encoder(feat)
        feat = d.dpgrnn(feat)                       # (B, 16, T, 33)
        m_feat = d.decoder(feat, en_outs)
        m = d.erb.bs(m_feat)

        spec_enh = spec_p * m                        # (B, 2, T, F)
        spec_enh = spec_enh.permute(0, 3, 2, 1)      # (B, F, T, 2)
        return spec_enh


def main() -> int:
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)

    print("=== Loading ULUNAS denoiser ===")
    from LavaSR.denoiser.denoiser import LavaDenoiser
    from huggingface_hub import hf_hub_download

    weights_path = hf_hub_download("YatharthS/LavaSR", "denoiser/denoiser.bin")
    print(f"  weights: {weights_path}")

    denoiser = LavaDenoiser(weights_path, device="cpu")
    pytorch_model = denoiser.model
    pytorch_model.eval()
    n_params = sum(p.numel() for p in pytorch_model.parameters())
    print(f"  params: {n_params:,}")

    print()
    print("=== Wrapping for fixed-length export ===")
    wrapped = ULUNASExport(pytorch_model)
    wrapped.eval()

    # Verify the wrapper matches the original on a real input (modulo
    # the tail-pad zeros that the original would add for length
    # mismatches; for a 128k input we expect them to match exactly).
    print()
    print(f"=== Tracing wrapped model (input shape [1, {INPUT_LENGTH_SAMPLES}]) ===")
    example_input = torch.zeros(1, INPUT_LENGTH_SAMPLES, dtype=torch.float32)
    t0 = time.time()
    with torch.inference_mode():
        traced = torch.jit.trace(wrapped, example_input, strict=False)
    print(f"  traced in {time.time() - t0:.1f}s")

    # Sanity-check the trace: wrapped vs traced should match.
    # Wrapper output is a SPECTROGRAM, original output is AUDIO — they
    # don't have the same shape, so we compare wrapper vs traced only
    # (both produce spectrograms), and verify the wrapper matches the
    # original via the END-TO-END Swift-side iSTFT below.
    test_audio = torch.randn(1, INPUT_LENGTH_SAMPLES, dtype=torch.float32) * 0.1
    with torch.inference_mode():
        wrap_out = wrapped(test_audio).cpu().numpy()
        traced_out = traced(test_audio).cpu().numpy()
    max_err_trace = float(np.max(np.abs(wrap_out - traced_out)))
    print(f"  wrapper output shape: {wrap_out.shape}  (B, F, T, 2)")
    print(f"  trace vs wrapper max |err|: {max_err_trace:.6e}")

    print()
    print("=== Converting to Core ML ===")
    import coremltools as ct

    # Monkey-patch coremltools 9.0's `_cast` to handle 1-element arrays
    # being passed to int() / float(). The bug: `_cast` does
    # `dtype(x.val)` where x.val can be a 1-D length-1 numpy array;
    # python's int() / float() require 0-D for arrays. Fix is to
    # `.item()` first.
    from coremltools.converters.mil.frontend.torch import ops as _ops
    from coremltools.converters.mil import Builder as _mb_module
    _original_cast = _ops._cast

    def _patched_cast(context, node, dtype, dtype_str):
        from coremltools.converters.mil.mil import Builder as mb
        inputs = _ops._get_inputs(context, node, expected=1)
        x = inputs[0]
        if x.val is not None:
            val = x.val
            # Handle 1-element non-0D arrays (the bug case)
            try:
                py_val = dtype(val)
            except (TypeError, ValueError):
                import numpy as _np
                arr = _np.asarray(val)
                if arr.size == 1:
                    py_val = dtype(arr.item())
                else:
                    py_val = arr.astype(dtype).tolist()
            res = mb.const(val=py_val, name=node.name)
        else:
            res = mb.cast(x=x, dtype=dtype_str, name=node.name)
        context.add(res)
    _ops._cast = _patched_cast
    print("  [patch] _cast monkey-patched to handle 1-element arrays")

    t0 = time.time()
    try:
        ml_model = ct.convert(
            traced,
            inputs=[
                ct.TensorType(
                    name="audio_in",
                    shape=(1, INPUT_LENGTH_SAMPLES),
                    dtype=np.float32,
                )
            ],
            outputs=[ct.TensorType(name="audio_out", dtype=np.float32)],
            minimum_deployment_target=ct.target.macOS15,
            compute_precision=ct.precision.FLOAT32,
            compute_units=ct.ComputeUnit.CPU_ONLY,
            convert_to="mlprogram",
        )
        print(f"  converted in {time.time() - t0:.1f}s")
    except Exception as e:
        print(f"  conversion FAILED after {time.time() - t0:.1f}s")
        print(f"  error: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        return 2

    mlpackage_path = FIXTURES_DIR / "lavasr_denoiser.mlpackage"
    if mlpackage_path.exists():
        import shutil
        shutil.rmtree(mlpackage_path)
    ml_model.save(str(mlpackage_path))
    size_bytes = sum(
        f.stat().st_size for f in mlpackage_path.rglob("*") if f.is_file()
    )
    print(f"  saved to {mlpackage_path} ({size_bytes / 1024:.1f} KB)")

    print()
    print("=== Verifying Core ML output vs PyTorch (spectrogram + iSTFT) ===")
    rng = np.random.default_rng(0xC0FFEE)
    fixture_in = (rng.standard_normal(INPUT_LENGTH_SAMPLES).astype(np.float32) * 0.1)
    fixture_t = torch.from_numpy(fixture_in).unsqueeze(0)

    # Reference: original ULUNAS end-to-end audio
    with torch.inference_mode():
        py_audio = pytorch_model(fixture_t).squeeze(0).cpu().numpy()

    # Core ML: predict masked spectrogram, then iSTFT in Python (mirrors
    # what the Swift side will do).
    ml_out_dict = ml_model.predict({"audio_in": fixture_in.reshape(1, -1)})
    ml_out_key = list(ml_out_dict.keys())[0]
    spec_real = ml_out_dict[ml_out_key]
    print(f"  Core ML spec shape: {spec_real.shape}  (expected (1, 257, 501, 2))")
    # Reconstruct complex + iSTFT
    spec_complex = torch.complex(
        torch.from_numpy(spec_real[..., 0]),
        torch.from_numpy(spec_real[..., 1]),
    )
    window = torch.hann_window(pytorch_model.win_len)
    ml_audio = torch.istft(
        spec_complex,
        n_fft=pytorch_model.n_fft,
        hop_length=pytorch_model.hop_len,
        win_length=pytorch_model.win_len,
        window=window,
        onesided=True,
        length=INPUT_LENGTH_SAMPLES,
    ).squeeze(0).cpu().numpy()

    # First compare spectrogram: pytorch wrapper vs Core ML
    with torch.inference_mode():
        py_spec = wrapped(fixture_t).cpu().numpy()
    spec_corr = float(np.corrcoef(py_spec.flatten(), spec_real.flatten())[0, 1])
    print(f"  spec Pearson r (Core ML vs PyTorch wrapper): {spec_corr:.6f}")

    # Then compare reconstructed audio
    max_err = float(np.max(np.abs(py_audio - ml_audio)))
    mean_err = float(np.mean(np.abs(py_audio - ml_audio)))
    sig_pow = float(np.mean(py_audio**2)) + 1e-12
    noi_pow = float(np.mean((py_audio - ml_audio) ** 2)) + 1e-12
    snr_db = 10.0 * np.log10(sig_pow / noi_pow)
    if py_audio.std() > 1e-9 and ml_audio.std() > 1e-9:
        corr = float(np.corrcoef(py_audio, ml_audio)[0, 1])
    else:
        corr = float("nan")
    print(f"  audio shapes: pytorch={py_audio.shape}, coreml+istft={ml_audio.shape}")
    print(f"  audio max |err|:  {max_err:.6e}")
    print(f"  audio mean |err|: {mean_err:.6e}")
    print(f"  audio SNR:        {snr_db:.1f} dB")
    print(f"  audio Pearson r:  {corr:.6f}")

    if corr >= 0.98:
        print()
        print(f"  ✓ Pearson ≥ 0.98 — Core ML + Python-iSTFT round-trips faithfully")
    else:
        print()
        print(f"  ✗ Pearson < 0.98 — drift exists; investigate before shipping")
        return 3

    # Dump golden: input audio, Core ML spectrogram (for Swift parity test),
    # final reconstructed audio
    np.save(FIXTURES_DIR / "lavasr_denoiser_golden_random_input.npy",
            fixture_in.astype(np.float32))
    np.save(FIXTURES_DIR / "lavasr_denoiser_golden_random_spec.npy",
            spec_real.astype(np.float32))
    np.save(FIXTURES_DIR / "lavasr_denoiser_golden_random_audio.npy",
            ml_audio.astype(np.float32))
    print(f"  golden dumps written to {FIXTURES_DIR}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
