# Pocket TTS macOS

A fully native macOS app that replaces the [Electron-based Pocket TTS](https://github.com/slaughters85j/pocket-tts) frontend with a Python-free, on-device text-to-speech application. Runs two TTS backends — Kyutai's Pocket-TTS (~100M params, Core ML) and Fish Audio S2 Pro (~5B params, MLX) — with unified voice management, LavaSR voice enhancement, and LM Studio chat integration.

## Why This Exists

The original Pocket TTS ships as an Electron app wrapping a Python backend (FastAPI + PyTorch). That stack works, but it means bundling a full Python runtime via PyInstaller (~200 MB), managing a background server process, and accepting Electron's memory overhead. This project converts the entire pipeline to native Swift/Core ML/MLX, producing a single `.app` with ~0.17s first-audio latency and ~3x real-time throughput on Apple Silicon.

## Dual TTS Backends

### Pocket-TTS (100M, Core ML)

The Python TTS model was converted to three Core ML `.mlpackage` artifacts via a separate [conversion project](https://github.com/slaughters85j/pocket-tts-core-ml-conversion):

| Model | Size | Role |
|-------|-----:|------|
| `prompt_phase.mlpackage` | 140 MB fp16 | Encodes text tokens + voice into KV cache |
| `calm_stateful.mlpackage` | 162 MB fp16 | Autoregressive decoder — one latent frame per 80ms step |
| `mimi_stateful.mlpackage` | 20 MB fp16 | Streaming neural codec — converts latents to 1920 PCM samples |
| `voice_prompt_phase.mlpackage` | 265 MB fp32 | Bakes voice conditioning into KV cache for imported voices |

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

## Voice Management

The Voice Manager (waveform icon in the app header) is the canonical place to import, enhance, and manage voices for both backends. One WAV import produces voices for both engines automatically.

**Import pipeline:**
```
WAV → [LavaSR enhancement (optional)] → [Fish DAC encode] + [MimiEncoder → voice_prompt_phase → KV safetensors]
```

- **LavaSR Enhancement** — MLX-native port of the Vocos BWE (bandwidth extension) model. Uses a custom ISTFT head matching the Python Vocos pipeline exactly: periodic Hann window, window-squared overlap-add normalization, and "same" padding. Best suited for noisy or low-quality recordings — clean studio audio may sound worse after enhancement due to inherent model artifacts.
- **RMS Normalization** — All imported voices are automatically RMS-normalized to -16 dB at import time, ensuring consistent volume for encoding regardless of whether enhancement is applied.
- **Enhancement Studio** — A/B comparison (Play original vs enhanced), Accept & Save / Reject / Re-enhance flow. Denoise toggle and RMS target level (-30 to -6 dB) configurable per voice.
- **Mono preconditioning** — Stereo or non-44.1kHz WAVs are automatically converted to mono 44.1kHz at import time for consistent downstream processing.
- **Memory management** — All import models (MimiEncoder, LavaSR, voice_prompt_phase) unload after encoding. Fish engine unloads when switching to Pocket-TTS. MLX GPU cache cleared on unload.

## AI Script Writer

Both Single Voice and Multi-Talk views have an "AI Write" button that opens an LLM-powered script generation modal. Describe what you want in natural language, the connected LLM streams a formatted script, and "Use Script" commits it to the editor.

- **Single Voice**: returns plain spoken text
- **Multi-Talk**: returns `{Speaker N}` tagged dialogue with configurable speaker count (2-6)
- System prompts independently scoped per mode, editable inline

## Features

- **Single Voice** — text editor, voice picker, synthesize, inline audio player
- **Multi-Talk** — multi-speaker scripts with `{Speaker}` tags and `[Xs]` pause markers
- **Chat** — LM Studio integration with streaming TTS, dictation, transcript export, orb visualizer
- **History** — SwiftData-backed log with "Reuse Setup"
- **Text Normalizer** — numbers, currency, units, abbreviations, domain terms, acronyms (~1000 lines)
- **Metal Orb** — raymarched volumetric plasma driven by real-time audio amplitude

## Requirements

- macOS 15+ (Core ML stateful models require it)
- Xcode 16+ (Swift 6)
- Apple Silicon (required for MLX / Fish backend; Pocket-TTS works on Intel but not optimized)
- ~410 MB for Pocket-TTS models + ~56 MB LavaSR weights + ~73 MB MimiEncoder weights
- Fish S2 Pro weights (~3.5 GB) downloaded on first selection from HuggingFace
- [LM Studio](https://lmstudio.ai/) for Chat tab and AI Script Writer (optional)

## Building

```bash
xcodebuild -project pocket-tts-macos.xcodeproj \
    -scheme pocket-tts-macos \
    -destination 'platform=macOS' \
    -configuration Debug build

# Run tests
xcodebuild -project pocket-tts-macos.xcodeproj \
    -scheme pocket-tts-macos \
    -destination 'platform=macOS' test
```

## Remaining Work

| Item | Status |
|------|--------|
| LavaSR audio quality tuning | In progress — slight artifacts in enhanced output |
| ULUNAS denoiser port | Planned — currently BWE only |
| Phase 6: signing, notarization, Sparkle, DMG | Planned |
| iOS variant | Deferred to v2 |

## Related Projects

| Project | Role |
|---------|------|
| [pocket-tts](https://github.com/slaughters85j/pocket-tts) | Original Python/Electron app — reference implementation |
| [pocket-tts-core-ml-conversion](https://github.com/slaughters85j/pocket-tts-core-ml-conversion) | Core ML conversion scripts, validators, Swift CLI harness |
| [mlx-audio-swift (fork)](https://github.com/slaughters85j/mlx-audio-swift) | Forked to expose Fish S2 Pro codec + refCodes API |

## Authors

**Upstream (Kyutai):** Manu Orsini, Simon Rouard, Gabriel De Marmiesse, Vaclav Volhejn, Neil Zeghidour, Alexandre Defossez

**This project:** John Saunders — Core ML conversion, native macOS app, Fish integration, MimiEncoder Swift port, LavaSR enhancement, Metal orb, text normalizer, streaming engine
