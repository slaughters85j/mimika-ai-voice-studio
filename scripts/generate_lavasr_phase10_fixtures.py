#!/usr/bin/env python3
"""
Generate Phase 10 LavaSR test fixtures.

Produces three 8-second voice WAV files at 16 kHz mono used by the
LavaSR parity tests:

    pocket-tts-macosTests/Fixtures/lavasr_phase10/
        lavasr_fixture_studio_clean_8s.wav    — clean macOS-`say` synthesis
        lavasr_fixture_phone_noisy_8s.wav     — studio + AWGN (-15 dB SNR)
                                              + telephone-band attenuation
        lavasr_fixture_webcam_8s.wav          — studio + lighter noise
                                              (-25 dB SNR) + room IR

These fixtures are deterministic — `say` produces byte-identical output
given the same voice + text + rate, and the noise/filter passes use a
fixed RNG seed. Re-running this script overwrites the fixtures with
identical bytes.

Usage:
    cd /Users/system-backup/dev_local/pocket-tts-macos
    /Users/system-backup/Library/Application\\ Support/pocket-tts-electron/lavasr-venv/bin/python \\
        scripts/generate_lavasr_phase10_fixtures.py

No LavaSR-specific dependencies — just numpy + soundfile + macOS `say`.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf


REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURES_DIR = REPO_ROOT / "pocket-tts-macosTests" / "Fixtures" / "lavasr_phase10"

# Voice / text are both deterministic — bumping either rotates fixtures.
SAY_VOICE = "Samantha"
SAY_RATE = 175
FIXTURE_TEXT = (
    "Testing the voice enhancement pipeline. "
    "The quick brown fox jumps over the lazy dog. "
    "This recording is exactly eight seconds long, designed to exercise "
    "the denoiser, the bandwidth extender, and the linkwitz merge stage."
)

TARGET_SR = 16_000
TARGET_DURATION_SEC = 8.0  # samples are truncated/padded to exactly this
RNG_SEED = 0xC0FFEE


def _say_to_wav(text: str, dest: Path, voice: str = SAY_VOICE, rate: int = SAY_RATE) -> None:
    """Synthesize `text` via macOS `say` and decode to 16 kHz mono WAV."""
    with tempfile.TemporaryDirectory() as tmp:
        aiff = Path(tmp) / "out.aiff"
        subprocess.run(
            ["say", "-o", str(aiff), "--voice", voice, "-r", str(rate), text],
            check=True,
        )
        subprocess.run(
            [
                "afconvert", str(aiff),
                "-d", "LEI16@16000",
                "-c", "1",
                "-f", "WAVE",
                str(dest),
            ],
            check=True,
        )


def _to_target_length(samples: np.ndarray) -> np.ndarray:
    """Trim or zero-pad to exactly TARGET_DURATION_SEC at TARGET_SR."""
    target = int(round(TARGET_DURATION_SEC * TARGET_SR))
    if len(samples) >= target:
        return samples[:target]
    out = np.zeros(target, dtype=np.float32)
    out[: len(samples)] = samples
    return out


def _white_noise_at_snr(signal: np.ndarray, snr_db: float, rng: np.random.Generator) -> np.ndarray:
    """Generate AWGN scaled to the requested SNR vs `signal`."""
    sig_power = np.mean(signal**2) + 1e-12
    noise_power = sig_power / (10 ** (snr_db / 10.0))
    noise = rng.standard_normal(len(signal)).astype(np.float32)
    noise *= np.sqrt(noise_power / (np.mean(noise**2) + 1e-12))
    return noise


def _bandpass_telephone(signal: np.ndarray, sr: int = TARGET_SR) -> np.ndarray:
    """Telephone-band approximation: 300-3400 Hz via FFT brick-wall.

    A real telephone filter is gentler, but a brick-wall FFT mask gives
    a deterministic, dependency-free implementation suitable for test
    fixtures. The fixtures are characterizing *that bandwidth was
    removed* — not modeling a real codec.
    """
    n = len(signal)
    spec = np.fft.rfft(signal)
    freqs = np.fft.rfftfreq(n, d=1.0 / sr)
    mask = ((freqs >= 300.0) & (freqs <= 3400.0)).astype(np.float32)
    return np.fft.irfft(spec * mask, n=n).astype(np.float32)


def _room_ir(signal: np.ndarray, decay_sec: float, rng: np.random.Generator) -> np.ndarray:
    """Convolve with a short synthetic impulse response (early reflections).

    Models a small-room webcam capture: a few exponentially decaying
    reflections with random delays under 50 ms.
    """
    ir_len = int(round(0.06 * TARGET_SR))  # 60 ms tail
    ir = np.zeros(ir_len, dtype=np.float32)
    ir[0] = 1.0
    # 4 random early reflections
    for k in range(4):
        delay = rng.integers(int(0.005 * TARGET_SR), ir_len)
        gain = 0.4 * np.exp(-delay / (decay_sec * TARGET_SR)) * rng.uniform(0.5, 1.0)
        ir[delay] += float(gain)
    convolved = np.convolve(signal, ir, mode="full")[: len(signal)]
    # Renormalize to keep RMS roughly the same as the input
    sig_rms = np.sqrt(np.mean(signal**2) + 1e-12)
    out_rms = np.sqrt(np.mean(convolved**2) + 1e-12)
    return (convolved * (sig_rms / out_rms)).astype(np.float32)


def _peak_normalize(signal: np.ndarray, peak: float = 0.85) -> np.ndarray:
    """Scale to a fixed peak so each fixture has comparable level."""
    cur_peak = float(np.max(np.abs(signal)) + 1e-12)
    return (signal * (peak / cur_peak)).astype(np.float32)


def generate() -> None:
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(RNG_SEED)

    # 1) Studio-clean base.
    print(f"[1/3] Generating studio-clean fixture via `say` ({SAY_VOICE}, rate {SAY_RATE})...")
    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "raw.wav"
        _say_to_wav(FIXTURE_TEXT, raw)
        clean, sr = sf.read(str(raw), dtype="float32")
    assert sr == TARGET_SR, f"unexpected SR from afconvert: {sr}"
    clean = _to_target_length(clean)
    clean = _peak_normalize(clean)
    studio_path = FIXTURES_DIR / "lavasr_fixture_studio_clean_8s.wav"
    sf.write(str(studio_path), clean, TARGET_SR, subtype="FLOAT")
    print(f"      → {studio_path.name}  ({studio_path.stat().st_size / 1024:.1f} KB)")

    # 2) Phone-noisy variant: bandlimit + heavy AWGN.
    print("[2/3] Generating phone-noisy fixture (300-3400 Hz + AWGN @ -15 dB SNR)...")
    phone_band = _bandpass_telephone(clean)
    phone_noise = _white_noise_at_snr(phone_band, snr_db=15.0, rng=rng)
    phone = _peak_normalize(phone_band + phone_noise)
    phone_path = FIXTURES_DIR / "lavasr_fixture_phone_noisy_8s.wav"
    sf.write(str(phone_path), phone, TARGET_SR, subtype="FLOAT")
    print(f"      → {phone_path.name}  ({phone_path.stat().st_size / 1024:.1f} KB)")

    # 3) Webcam variant: room reverb + lighter AWGN.
    print("[3/3] Generating webcam fixture (room IR + AWGN @ -25 dB SNR)...")
    webcam_reverb = _room_ir(clean, decay_sec=0.05, rng=rng)
    webcam_noise = _white_noise_at_snr(webcam_reverb, snr_db=25.0, rng=rng)
    webcam = _peak_normalize(webcam_reverb + webcam_noise)
    webcam_path = FIXTURES_DIR / "lavasr_fixture_webcam_8s.wav"
    sf.write(str(webcam_path), webcam, TARGET_SR, subtype="FLOAT")
    print(f"      → {webcam_path.name}  ({webcam_path.stat().st_size / 1024:.1f} KB)")

    print()
    print(f"Done. {len(list(FIXTURES_DIR.glob('lavasr_fixture_*.wav')))} fixtures in {FIXTURES_DIR}")


def main() -> int:
    # Verify macOS tooling
    for tool in ("say", "afconvert"):
        if shutil.which(tool) is None:
            print(f"error: required macOS tool not found: {tool}", file=sys.stderr)
            return 1
    generate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
