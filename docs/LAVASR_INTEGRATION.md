# LavaSR Voice Enhancement Integration Plan

## What LavaSR Does

LavaSR v2 (`YatharthS/LavaSR`) enhances voice recordings for TTS cloning:
- **Denoising** — removes background noise, hum, reverb
- **Audio cleanup** — improves clarity and consistency
- **RMS normalization** — levels output to a target dB (e.g., -14 dB)
- Outputs at 48kHz, resampled to target rate (24kHz for Pocket-TTS Mimi, 44.1kHz for Fish DAC)

The Electron app runs this as a Python sidecar subprocess (`enhance-voice.py`).

## Integration Options for the macOS App

### Option A: MLX-native port (recommended)

LavaSR v2 is a PyTorch model (~50M params). Port to mlx-swift:
1. Export LavaSR weights to safetensors
2. Implement the model architecture in Swift using MLX (Conv1d + transformer layers)
3. Run inference on Apple Silicon GPU via MLX — no Python, matches the "shed Electron" goal

**Effort:** ~2-3 days. Model is small (50M vs Fish's 5B). The architecture is mostly
Conv1d + self-attention, which mlx-swift handles well.

**Where it fits in the pipeline:**
```
Import WAV → [LavaSR enhance] → enhanced.wav → [Whisper transcribe] → [DAC encode] → cached codes
```

### Option B: Bundled Python sidecar (quick, not ideal)

Ship the existing `enhance-voice.py` script + a bundled Python runtime:
1. Bundle a minimal Python 3.10 with torch + LavaSR in the app's Resources
2. Spawn as a subprocess, parse JSON status lines from stdout
3. Works immediately — same code as Electron app

**Effort:** ~1 day. But adds ~500MB to app bundle (Python + torch) and contradicts
the "no Python" architecture goal.

### Option C: Core ML conversion

Convert LavaSR to Core ML:
1. Trace the model with `ct.convert()`
2. Run via Core ML (like the existing Pocket-TTS pipeline)

**Effort:** ~1 day for conversion. Risk: the Conv1d + transformer stack may have
the same fp16 precision issues as Fish's DAC decoder (17 dB SNR at fp16). Would
need fp32 fallback.

## Recommended: Option A (MLX-native)

### Files to Create

```
pocket-tts-macos/Engine/VoiceEnhancer.swift    (~200 lines)
  - Actor wrapping the MLX LavaSR model
  - `enhance(inputURL: URL, outputURL: URL, denoise: Bool) async throws`
  - RMS normalization built-in
  - Lazy model loading (like FishEngine.bootstrap())
```

### Integration Points

1. **FishVoiceManager.importVoice()** — after copying WAV, call `VoiceEnhancer.enhance()`
   before codec encoding. The pipeline becomes:
   ```
   copy WAV → enhance → save enhanced.wav → encode codes → save .safetensors
   ```

2. **VoiceManagerView** — add an "Enhance" toggle (default on) in the import section.
   Show enhancement status in the voice row ("Enhanced" / "Raw" badge).

3. **FishVoice model** — add `isEnhanced: Bool` field to track whether the voice
   was processed through LavaSR.

### LavaSR Model Details

- **Repo:** `YatharthS/LavaSR` on HuggingFace
- **Architecture:** UNet-style with Conv1d encoder + transformer bottleneck + Conv1d decoder
- **Input:** Mono audio at any sample rate (internally resampled to 48kHz)
- **Output:** Enhanced mono audio at 48kHz
- **Params:** ~50M
- **Inference:** ~2-3 seconds for 10s audio on M1 Ultra (estimated)
- **Device:** MPS (Apple Silicon GPU) preferred, CPU fallback

### Weight Export

From the Electron app's Python environment:
```python
from LavaSR.model import LavaEnhance2
import safetensors.torch

model = LavaEnhance2("YatharthS/LavaSR", "cpu")
safetensors.torch.save_file(model.model.state_dict(), "lavasr_v2.safetensors")
```

Then load in mlx-swift via `MLX.loadArrays(url:)` and build the model architecture
mirroring the PyTorch implementation.

### Dependencies

- mlx-swift (already in project)
- No additional SPM packages needed
- Model weights: ~100MB safetensors (download on first use, like Fish)
