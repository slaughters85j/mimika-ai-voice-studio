# Pocket TTS macOS

A fully native macOS app that replaces the [Electron-based Pocket TTS](https://github.com/slaughters85j/pocket-tts) frontend with a Python-free, on-device text-to-speech application. Runs two TTS backends — Kyutai's Pocket-TTS (~100M params, Core ML) and Fish Audio S2 Pro (~5B params, MLX) — with unified voice management, LavaSR voice enhancement, and LM Studio chat integration.

## Why This Exists

The original Pocket TTS ships as an Electron app wrapping a Python backend (FastAPI + PyTorch). That stack works, but it means bundling a full Python runtime via PyInstaller (~200 MB), managing a background server process, and accepting Electron's memory overhead. This project converts the entire pipeline to native Swift/Core ML/MLX, producing a single `.app` with ~0.17s first-audio latency and ~3x real-time throughput on Apple Silicon.

## Dual TTS Backends

### Pocket-TTS (100M, Core ML)

The Python TTS model was converted to three Core ML `.mlpackage` artifacts via a separate [conversion project](https://github.com/slaughters85j/pocket-tts-core-ml-conversion):

| Model | Size | Role |
|-------|-----:|------|
| `prompt_phase.mlpackage` | 134 MB fp16 | Encodes text tokens + voice into KV cache |
| `calm_stateful.mlpackage` | 325 MB fp32 compute | Autoregressive decoder — one latent frame per 80ms step |
| `mimi_stateful.mlpackage` | 39 MB fp32 compute | Streaming neural codec — converts latents to 1920 PCM samples |
| `voice_prompt_phase.mlpackage` | 265 MB fp32 | Bakes voice conditioning into KV cache for imported voices |

CaLM and Mimi are converted with `compute_precision=FLOAT32` (state buffers remain fp16 — coremltools 9.0 doesn't yet support fp32 state). The fp32 compute path eliminates two issues the original fp16 builds had on long generations: per-step AR drift that compounded across 30+ frame chunks, and a Mimi K/V buffer overflow (cache sized for 64 frames, real chunks ran 100+) that produced silent stale-attention reads in the back half of long sentences. After the rebuild, drift is flat past 100 steps and 1.4e-4 vs the fp32 PyTorch reference on the back third of a 106-frame sentence.

Seven predefined voices ship as precomputed KV states. Custom voices are imported via the Voice Manager and baked in-app using a native MLX port of the Mimi encoder (18M params).

### Fish Audio S2 Pro (5B, MLX)

Added via a [forked mlx-audio-swift](https://github.com/slaughters85j/mlx-audio-swift) (exposes codec + refCodes generation path). Fish provides higher-quality zero-shot voice cloning from reference audio.

| Feature | Pocket-TTS | Fish S2 Pro |
|---------|-----------|-------------|
| Model size | 100M | 5B |
| Runtime | Core ML | MLX (mlx-swift) |
| Voice cloning | Imported WAV → MimiEncoder → KV states | Imported WAV → DAC codec indices |
| Latency | Sub-second first audio | ~20-45s per segment |
| Quality | Good for short-form | Excellent for voice cloning |

Both backends conform to `TTSEngineProtocol`. Switching between them is a picker selection — the active engine swaps at runtime with automatic memory management (inactive backend unloads from RAM).

### Fish Performance: Reference Audio Length Benchmark

Benchmarked on M1 Ultra with the same 57-character input text, varying reference audio from 3s to 20s:

| Ref (s) | Codes | Gen (s) | Audio (s) | RTF | chars/s |
|---------|-------|---------|-----------|------|---------|
| 3 | 65 | 28.84 | 4.04 | 0.14x | 2.0 |
| 6 | 130 | 27.89 | 4.13 | 0.15x | 2.0 |
| 9 | 194 | 33.40 | 4.88 | 0.15x | 1.7 |
| 12 | 259 | 29.52 | 4.37 | 0.15x | 1.9 |
| 15 | 323 | 33.36 | 4.92 | 0.15x | 1.7 |
| 20 | 431 | 25.50 | 3.81 | 0.15x | 2.2 |

**Key findings:**
- **Reference length does not affect generation speed.** The ~30% variance (25-33s) is noise from thermal throttling and non-deterministic output length, not from attention over reference codes.
- **The bottleneck is the autoregressive decode loop** — each output token has a fixed inference cost regardless of context length. Generation runs at ~0.15x real-time consistently.
- **15 seconds is the quality sweet spot** for reference audio — enough voice signal for high-fidelity cloning without diluting it. Shorter clips (3-6s) produce noticeably lower quality; 20s offers no improvement over 15s.
- **Pocket-TTS generates the same text in 2.11s** (2.9x real-time, 27 chars/s) — ~15x faster than Fish.

The benchmark test is in `pocket-tts-macosTests/FishRefLengthBenchmark.swift`.

## Voice Management

The Voice Manager (waveform icon in the app header) is the canonical place to import, enhance, and manage voices for both backends. One WAV import produces voices for both engines automatically.

**Import pipeline:**
```
WAV → [LavaSR enhancement (optional)] → [Fish DAC encode] + [MimiEncoder → voice_prompt_phase → KV safetensors]
```

**Storage:** Saved voices live in the app's sandbox container — `~/Library/Containers/<bundle-id>/Data/Library/Application Support/pocket-tts-macos/saved-voices/`. Each voice is a triplet (`<UUID>.wav`, `<UUID>_codes.npy`, `<UUID>_kv.safetensors`) plus an optional `<UUID>_enhanced.wav`, with a `voices.json` catalog at the same directory. The catalog stores basenames only — paths are resolved against the current container at load time so the catalog survives sandbox migrations, bundle-ID changes, and backup restores. The seven Kyutai stock voices ship in `Resources/voice_kv_states/` in the app bundle; custom voices never enter source.

- **LavaSR Enhancement** — MLX-native port of the Vocos BWE (bandwidth extension) model. Uses a custom ISTFT head matching the Python Vocos pipeline exactly: periodic Hann window, window-squared overlap-add normalization, and "same" padding. Off by default for new voices until the ULUNAS denoiser port + artifact tuning land; can introduce perceptible artifacts on clean source audio. Best suited for noisy or low-quality recordings.
- **RMS Normalization** — All imported voices are automatically RMS-normalized to -16 dB at import time, ensuring consistent volume for encoding regardless of whether enhancement is applied.
- **Per-voice loudness target** — Each saved voice carries its own RMS target (-30 to -6 dB) configured in the Enhancement Studio. Single Voice applies the target automatically as a streaming-friendly static gain relative to the -16 dB conditioning baseline. Multi-Talk adds a 3-way segmented picker (Per voice / Match loudest / Match quietest) mirroring the Electron reference, so multi-speaker dialogues can be balanced without re-baking voice KV states.
- **Enhancement Studio** — A/B comparison (Play original vs enhanced), Accept & Save / Reject / Re-enhance flow. Denoise toggle and RMS target level (-30 to -6 dB) configurable per voice.
- **Mono preconditioning** — Stereo or non-44.1kHz WAVs are automatically converted to mono 44.1kHz at import time for consistent downstream processing.
- **Memory management** — All import models (MimiEncoder, LavaSR, voice_prompt_phase) unload after encoding. Fish engine unloads when switching to Pocket-TTS. MLX GPU cache cleared on unload.
- **Reconcile-on-boot** — Stale catalog rows (files vanished since last launch) get their path fields nulled at startup, before any UI mounts. Logs `[VoiceManager] reconcile: cleared N stale path(s)` when applicable. Idempotent.
- **Recover from Disk** — When `saved-voices/` contains `<UUID>_kv.safetensors` files with no matching catalog row, the Voice Manager shows a "Recover from Disk" section listing the adoptable orphans (KV header parses + companion WAV present). Type a display name → Adopt → catalog row created. Unparseable / partial orphans are logged but not surfaced.
- **Name collision rejection** — Importing with a name that case-insensitively matches an existing voice fails inline on the Save Voice Preset screen instead of silently creating a duplicate. Other import failures (disk, conversion) surface the same way.

## AI Script Writer

Both Single Voice and Multi-Talk views have an "AI Write" button that opens an LLM-powered script generation modal. Describe what you want in natural language, the connected LLM streams a formatted script, and "Use Script" commits it to the editor.

- **Single Voice**: returns plain spoken text
- **Multi-Talk**: returns `{Speaker N}` tagged dialogue with configurable speaker count (2-6)
- System prompts independently scoped per mode, editable inline

## Features

- **Single Voice** — text editor, voice picker, synthesize, inline audio player
- **Multi-Talk** — multi-speaker scripts with `{Speaker}` tags and `[Xs]` pause markers
- **Chat** — LM Studio integration with streaming TTS, dictation, transcript export, orb visualizer
- **Voice Changer** — drop an audio/video file, transcribe via Parakeet TDT v3 through FluidAudio, re-voice with any installed voice while preserving the original timeline (silence + pause structure)
- **Speaker Isolation** — drop a multi-speaker audio/video file, diarize via SpeakerKit (Argmax's on-device pyannote), get per-speaker isolated tracks + a Background pseudo-row. Per-speaker actions: Use Original / Discard / Re-voice. Closed-loop video output via AVFoundation re-mux.
  - **Audio Preservation** (optional, opt-in) — when enabled, an on-device HTDemucs Core ML model separates the input into vocals + drums + bass + other stems. Re-voiced speakers ride on top of the preserved music stem, so background audio survives the re-voice. Model is a 287 MB user-downloaded `.mlpackage`; soft-falls back to v1 (music goes silent under revoiced speech) when not installed, with a banner pointing at the Manage Separation Models sheet.
- **History** — SwiftData-backed log with "Reuse Setup"
- **Text Normalizer** — numbers, currency, units, abbreviations, domain terms, acronyms (~1000 lines)
- **Metal Orb** — raymarched volumetric plasma driven by real-time audio amplitude

## Requirements

- macOS 15+ (Core ML stateful models require it)
- Xcode 16+ (Swift 6)
- Apple Silicon (required for MLX / Fish backend; Pocket-TTS works on Intel but not optimized)
- ~500 MB for Pocket-TTS models (fp32-compute CaLM + Mimi) + ~56 MB LavaSR weights + ~73 MB MimiEncoder weights
- Fish S2 Pro weights (~3.5 GB) downloaded on first selection from HuggingFace
- [LM Studio](https://lmstudio.ai/) for Chat tab and AI Script Writer (optional)

## Building

```bash
# 1. Sync models + tokenizer + voice KV states into Resources/
./scripts/sync-assets.sh

# 2. Build (Debug)
xcodebuild -project pocket-tts-macos.xcodeproj \
    -scheme pocket-tts-macos \
    -destination 'platform=macOS' \
    -configuration Debug build

# Run tests
xcodebuild -project pocket-tts-macos.xcodeproj \
    -scheme pocket-tts-macos \
    -destination 'platform=macOS' test
```

### Release archives

The source tree's `Resources/voice_kv_states/` is stock-only by construction — `sync-assets.sh` only copies the seven Kyutai voices, and custom voices live exclusively in the user's app container. So the archive workflow is just:

```bash
./scripts/sync-assets.sh
xcodebuild archive ...
# sign + notarize
```

No pre-archive strip step. Verify by listing `.app/Contents/Resources/*.safetensors` after building — should show only `alba`, `azelma`, `cosette`, `fantine`, `javert`, `jean`, `marius` alongside the `lavasr_*` and `mimi_encoder_*` model weights.

## Remaining Work

| Item | Status |
|------|--------|
| LavaSR audio quality tuning | In progress — slight artifacts in enhanced output |
| ULUNAS denoiser port | Planned — currently BWE only |
| Sparkle auto-update + DMG | Planned (signing + notarization done) |
| iOS variant | Deferred to v2 |

## Related Projects

| Project | Role |
|---------|------|
| [pocket-tts](https://github.com/slaughters85j/pocket-tts) | Original Python/Electron app — reference implementation |
| [pocket-tts-core-ml-conversion](https://github.com/slaughters85j/pocket-tts-core-ml-conversion) | Core ML conversion scripts, validators, Swift CLI harness for the Pocket-TTS models |
| [pocket-tts-demucs-coreml-conversion](https://github.com/slaughters85j/pocket-tts-demucs-coreml-conversion) | PyTorch → Core ML conversion + numerical-parity validators for the Phase 7 HTDemucs source-separation model. Published artifact lives at [`slaughters85j/htdemucs-coreml`](https://huggingface.co/slaughters85j/htdemucs-coreml) on Hugging Face (MIT, FP32, 287 MB zipped). |
| [mlx-audio-swift (fork)](https://github.com/slaughters85j/mlx-audio-swift) | Forked to expose Fish S2 Pro codec + refCodes API |

## Authors

**Upstream (Kyutai):** Manu Orsini, Simon Rouard, Gabriel De Marmiesse, Vaclav Volhejn, Neil Zeghidour, Alexandre Defossez

**This project:** John Saunders — Core ML conversion, native macOS app, Fish integration, MimiEncoder Swift port, LavaSR enhancement, Metal orb, text normalizer, streaming engine
