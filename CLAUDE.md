# CLAUDE.md

Single-shot context for any Claude Code session working in this repo. Read first.

> **Note:** This file is intentionally checked in (no symlink trick) so the project is self-contained for fresh sessions.

---

## Project Overview

**pocket-tts-macos** is a native Swift / SwiftUI macOS app that replaces the existing Electron-based pocket-tts frontend with a fully on-device, Python-free TTS application. It runs the Kyutai pocket-tts model end-to-end via Core ML `.mlpackage` artifacts (CaLM + Mimi codec), with no Python server, no PyInstaller bundle, and no network dependency for synthesis.

- **Bundle ID:** `com.slaughtersj.pocket-tts-macos`
- **Min deployment target:** **macOS 15** (Core ML stateful models require it)
- **Lifecycle:** SwiftUI App
- **Swift version:** 6 (Xcode 16+)
- **Concurrency:** Swift Concurrency throughout — no GCD / DispatchQueue unless interfacing with AVAudioEngine taps
- **Architecture targets:** Apple Silicon primary; Intel build acceptable but not optimized
- **iOS variant:** **possibly later** — design engine layer platform-agnostic, but no `#if os(iOS)` work in v1
- **License-relevant:** uses the ungated **pocket-tts-without-voice-cloning** model variant for v1. Voice cloning (gated checkpoint) is v2+.

---

## Current Status

**Phase −1 (project bootstrap) — in progress.** See `pocket-tts-macos/road-map.md` for the full phased plan.

What exists today (2026-05-15):

- Xcode project created, default `pocket_tts_macosApp.swift` + `ContentView.swift` + `Item.swift` templates only
- Git initialized + GitHub remote
- `road-map.md` checked in at `pocket-tts-macos/road-map.md`
- **Nothing else yet** — engine, UI, assets, dependencies all pending

---

## Source-of-truth file paths

### External reference projects (READ-ONLY — do not modify)

| Path | What it is | Why we look at it |
|------|------------|-------------------|
| `/Users/system-backup/dev_local/pocket-tts/` | Original Python pocket-tts repo | Ground-truth model implementation; reference for engine semantics |
| `/Users/system-backup/dev_local/pocket-tts-core-ml-conversion/` | Conversion project that produced our `.mlpackage`s | Source of artifacts + numerical validators + working Swift harness |

**Specifically useful files in those projects:**

- `pocket-tts/pocket_tts/models/tts_model.py` — `TTSModel` orchestration (autoregressive loop, KV cache slicing, decoder thread)
- `pocket-tts/pocket_tts/models/flow_lm.py` — `FlowLMModel`, LSD flow head
- `pocket-tts/pocket_tts/config/b6369a24.yaml` — full model hyperparameters
- `pocket-tts/electron/src/renderer/components/*.tsx` — the 16 React components to port (visual reference only — re-implement in SwiftUI)
- `pocket-tts/electron/src/renderer/lib/streaming-wav-player.ts` — progressive playback reference for `StreamingPlayer.swift`
- `pocket-tts/electron/src/main/llm-handler.ts` — LM Studio integration reference
- `pocket-tts/macos-service/PocketTTSMenuBar/Sources/PocketTTSMenuBar/Models/{Voice,Config}.swift` — **port these**; adapt namespaces
- `pocket-tts-core-ml-conversion/NOTES.md` — Core ML conversion gotchas (RoPE bug, fp16-only StateType, slice_update behavior). Re-read before touching the engine.
- `pocket-tts-core-ml-conversion/swift_harness/Sources/PocketTTSHarness/main.swift` — working Swift CLI that loads `calm_stateful` + `mimi_stateful`, runs the loop with seeded KV cache, writes WAV. **Mine this for the engine implementation.**
- `pocket-tts-core-ml-conversion/scripts/03_convert_calm_stateful.py` — Stage 3 converter; pattern to copy for `prompt_phase.mlpackage`

### Core ML artifacts (already converted, validated against PyTorch reference)

Located at `/Users/system-backup/dev_local/pocket-tts-core-ml-conversion/mlpackages/`:

| File | Size | Role in pipeline |
|------|-----:|------------------|
| `calm_stateful.mlpackage` | 162 MB fp16 | Autoregressive single-step decoder; 12 `ct.StateType` KV buffers; called once per 80 ms frame |
| `mimi_stateful.mlpackage` | 20 MB fp16 | Streaming Mimi decoder; converts one latent frame → 1920 PCM samples |
| `prompt_phase.mlpackage` | **140 MB fp16** | Text-encoding prompt: takes padded SentencePiece tokens + voice_offset + text_length → writes positions `voice_offset..voice_offset+T_TEXT_MAX` into the 12 KV state buffers. `T_TEXT_MAX = 128`. **Built and numerically validated** (1.84% worst K rel-err vs PyTorch). |
| `calm_step.mlpackage` | 325 MB fp32 | Stateless dev artifact (KV passed in/out). Keep around for debugging, do **not** bundle. |
| `mimi_decoder.mlpackage` | 39 MB fp32 | Stateless dev artifact. Do **not** bundle. |

### Model assets (also bundle inside the app)

- **Tokenizer:** `~/.cache/huggingface/hub/models--kyutai--pocket-tts-without-voice-cloning/snapshots/<hash>/tokenizer.model` — SentencePiece BPE
- **Voice KV state (precomputed):** `/Users/system-backup/dev_local/pocket-tts-core-ml-conversion/voice_kv_states/*.safetensors` — **bundle these, not the raw embeddings**
  - One file per voice: `alba.safetensors`, `azelma.safetensors`, `cosette.safetensors`, `fantine.safetensors`, `javert.safetensors`, `jean.safetensors`, `marius.safetensors`
  - Each file: 12 fp16 tensors (`kv_k_0..kv_k_5`, `kv_v_0..kv_v_5`) of shape `[1, 512, 16, 64]`, zero-padded beyond `T_voice`
  - Per-file size: ~12 MB. Total for 7 voices: ~84 MB
  - JSON metadata in each file's safetensors header carries `T_voice`, `n_layers`, `n_heads`, `d_head`, `max_seq`, `dtype` — Swift reads `T_voice` from metadata to know where to start writing in `prompt_phase`
  - Swift loads these directly via `MLState.write_state(name, fp32_view)` — coremltools' Python API requires fp32 input, but the Swift API accepts the native fp16 directly via `MLState.withMultiArray`

**Bundle size budget (Phase 0 artifacts):**
- 3 × `.mlpackage` (prompt_phase 140 + calm_stateful 162 + mimi_stateful 20) = ~320 MB
- 7 × voice KV files = ~84 MB
- Tokenizer + assets = ~5 MB
- **Total: ~410 MB** (revised up from initial ~250 MB estimate — note for App Store size warnings)

---

## Architecture (Core ML pipeline)

```
At app launch (once per voice selection):
  voice_kv_states/<voice>.safetensors  →  load fp16 K/V tensors
                                       →  MLState.write_state into all 4 mlpackage states
                                          (prompt_phase + calm_stateful share state contents
                                           by re-using the same KV layout; mimi_stateful has
                                           its own separate per-frame state)

Per synthesis call:
  User text → SentencePiece (Swift) → token IDs (padded to T_TEXT_MAX=128)
                                         ↓
        prompt_phase.mlpackage(text_tokens, voice_offset=T_voice, text_length=N)
                                         ↓
                       state buffers now contain voice KV (pos 0..T_voice)
                       + text KV (pos T_voice..T_voice+N)
                                         ↓
                       returns t_prompt = T_voice + N
                                         ↓
        ┌──────── per-frame autoregressive loop (frame_idx = 0, 1, 2, ...) ────────┐
        │                                                                           │
        │  calm_stateful.mlpackage(prev_latent, offset=t_prompt + frame_idx, noise) │
        │                          ──► one latent frame, EOS flag                   │
        │                          (KV state mutated in-place at the offset slot)   │
        │                                       │                                   │
        │                                       ▼                                   │
        │  mimi_stateful.mlpackage(latent)  ──► 1920 PCM samples (80 ms @ 24 kHz)  │
        │                                       │                                   │
        └───────────────────────────────────────┼───────────────────────────────────┘
                                                ▼
                                       AsyncStream<PCMFrame>
                                                ↓
                                       StreamingPlayer (AVAudioEngine)
                                                ↓
                                  speakers + WAV/AAC/MP3 encoder
```

**State-sharing note:** `prompt_phase` and `calm_stateful` were converted with **identical state-buffer shapes and names** (12 buffers: `kv_k_0..5`, `kv_v_0..5`, each `[1, 512, 16, 64]` fp16). Swift maintains ONE logical KV cache and writes it into both models' state objects. The first call (`prompt_phase`) populates positions `0..t_prompt`; subsequent calls (`calm_stateful`) extend it one slot per frame.

- **Frame rate:** 12.5 Hz (80 ms / frame)
- **Sample rate:** 24 kHz mono
- **Steady-state throughput:** ~38 fps on M1 Ultra (~3× real-time)
- **EOS:** CaLM's EOS head signals end; pipeline runs `frames_after_eos` more then stops
- **Numerical equivalence:** validated end-to-end vs PyTorch reference; e2e spectrum correlation 0.97

Full conversion details in `pocket-tts-core-ml-conversion/NOTES.md`.

---

## Project layout (target — being built out)

```
pocket-tts-macos/
├── CLAUDE.md                          ← this file
├── pocket-tts-macos.xcodeproj/
├── pocket-tts-macos/
│   ├── road-map.md
│   ├── App/
│   │   └── PocketTTSMacOSApp.swift   (@main, rename from default template)
│   ├── Engine/
│   │   ├── TTSEngine.swift           (orchestrator)
│   │   ├── Tokenizer.swift           (SentencePiece wrapper)
│   │   ├── VoiceLoader.swift         (safetensors → MLMultiArray)
│   │   └── ModelPaths.swift          (bundle-resource resolution)
│   ├── Audio/
│   │   ├── StreamingPlayer.swift     (AVAudioEngine source node)
│   │   ├── WAVEncoder.swift
│   │   └── AACMP3Encoder.swift       (AVAssetWriter)
│   ├── Persistence/
│   │   └── DataModels.swift          (SwiftData @Model types — Phase 3)
│   ├── ViewModels/                    (Phase 2+)
│   ├── Views/
│   │   ├── ContentView.swift         (NavigationSplitView)
│   │   ├── SingleVoiceView.swift
│   │   ├── MultiTalkView.swift       (Phase 3)
│   │   ├── HistoryView.swift         (Phase 3)
│   │   └── ChatView.swift            (Phase 4)
│   ├── Components/
│   │   ├── VoiceSelector.swift
│   │   ├── SpeakerCard.swift
│   │   ├── Orb.swift                 (Phase 5)
│   │   ├── StatusIndicator.swift
│   │   ├── PauseModal.swift
│   │   ├── AudioPlayer.swift
│   │   └── SynthesizeButton.swift
│   ├── Networking/
│   │   └── LMStudioClient.swift      (Phase 4)
│   ├── Resources/                     (bundled assets — added in Xcode "Copy Bundle Resources")
│   │   ├── mlpackages/
│   │   │   ├── prompt_phase.mlpackage
│   │   │   ├── calm_stateful.mlpackage
│   │   │   └── mimi_stateful.mlpackage
│   │   ├── tokenizer.model
│   │   └── embeddings/*.safetensors
│   └── Assets.xcassets/
├── pocket-tts-macosTests/
└── pocket-tts-macosUITests/
```

---

## Common commands

```bash
# Build (CLI — uses xcode-builder-agent to avoid miniforge linker contamination)
xcodebuild -project pocket-tts-macos.xcodeproj -scheme pocket-tts-macos -configuration Debug build

# Test
xcodebuild -project pocket-tts-macos.xcodeproj -scheme pocket-tts-macos test

# Re-run Core ML numerical validators (in the conversion project, after touching the engine)
cd /Users/system-backup/dev_local/pocket-tts-core-ml-conversion
source .venv/bin/activate
python scripts/validate_stage3.py    # PASS expected
python scripts/e2e_python.py         # writes out/out_coreml.wav

# Generate prompt_phase.mlpackage (Phase 0)
cd /Users/system-backup/dev_local/pocket-tts-core-ml-conversion
source .venv/bin/activate
python scripts/05_convert_prompt_phase.py   # to be written
```

**⚠️ Xcode build warning:** Do NOT use bare `swift build` or `xcodebuild` if miniforge/conda is on PATH — it contaminates the linker. Either use the `xcode-builder-agent` subagent or run `env -i PATH=/usr/bin:/bin xcodebuild ...` for a clean shell.

---

## Conventions

### Swift code style (from `~/.claude/CLAUDE.md`)

- Use `// MARK:` for every class, struct, extension, and meaningful function group
- Don't delete comments; you may update them
- Modern UI elements only — sane defaults from SwiftUI, no AppKit hacks unless required
- Files over **300 lines** → refactor (move helpers into extensions or sibling files)
- **macOS + iOS portable** when possible; `#if os(iOS)` for UI deltas. Engine layer must stay pure (no UI imports).
- Use Swift Concurrency (`async/await`, `AsyncStream`) — not GCD — except where AVAudioEngine taps require callbacks

### Testing

- **XCTest for both unit and UI tests.** Do *not* adopt Swift Testing (the new `@Test`/`#expect` macro framework) — even though Xcode 16 scaffolds it by default, we standardize on XCTest for consistency with the existing `macos-service/PocketTTSMenuBar` codebase and to keep one mental model across the project.
- Unit tests live in `pocket-tts-macosTests/`, UI tests in `pocket-tts-macosUITests/`
- If Xcode generated `pocket_tts_macosTests.swift` using Swift Testing (`import Testing`, `@Test` funcs), **rewrite it to XCTest** (`import XCTest`, `final class … : XCTestCase`, `func testFoo()`) on first touch
- Engine-layer tests (`TTSEngine`, `Tokenizer`, `VoiceLoader`) belong in unit tests; visible-flow tests (text → audio plays) belong in UI tests

### SwiftData persistence (Phase 3 onward)

Strict 10-step pattern from `~/.claude/CLAUDE.md`:

1. Separate `@Model` types (persistence) from view models (`ObservableObject` with `@Published`)
2. View models expose computed `get`/`set` properties as UI bindings
3. **Debounced saves** — 1-second `scheduleSave()` timer, not save-per-keystroke
4. View model takes `ModelContext` via `setModelContext(_:)` on view `.onAppear`
5. Centralized `DataModels.swift` for all `@Model` types
6. Load via `ModelContext` query in view model init; create defaults if missing
7. `didSet` on `@Published` props → `scheduleSave()`
8. `saveChanges()` copies view-model state back to `@Model` then `try modelContext.save()`
9. Views own `@StateObject` parent VM; pass to children as `@ObservedObject`
10. Views never touch `ModelContext` or `@Model` types directly — only via the view model

### Brand tokens

This is **not** a Ubiquitous Analytics project. The UA brand-token rule does not apply. Design language is open — pull cues from the existing Electron app's aesthetic, then formalize once we have v1 shape.

### Coding workflow

- **Refactor over add.** Reuse existing types; check `pocket-tts-core-ml-conversion/swift_harness/` and `macos-service/PocketTTSMenuBar/` before writing new code from scratch
- No mocking in dev/prod code. Mocks live in `pocket-tts-macosTests/` only
- Don't introduce a new pattern or library to "fix" something — first exhaust the existing pattern, then propose replacement
- Don't make changes unrelated to the task at hand
- Keep an eye on impact across `Engine/`, `Audio/`, and `Views/` whenever the public API of `TTSEngine` shifts

---

## Hard rules — do NOT

- ❌ Modify anything under `/Users/system-backup/dev_local/pocket-tts/` (read-only reference)
- ❌ Modify anything under `/Users/system-backup/dev_local/pocket-tts-core-ml-conversion/` except for generating new `.mlpackage`s and validators
- ❌ Re-download model weights — they're already in `~/.cache/huggingface/hub/`
- ❌ Add a Python runtime / PyInstaller / `subprocess` to this app — the whole point is to escape Python
- ❌ Bundle `calm_step.mlpackage` or `mimi_decoder.mlpackage` (dev artifacts only)
- ❌ Hardcode bundle paths — use `Bundle.main.url(forResource:withExtension:)` via `ModelPaths.swift`
- ❌ Add CoreData (we use SwiftData)
- ❌ Touch `Item.swift` from the Xcode default template — delete it once `DataModels.swift` lands

---

## Decisions locked

| Question | Answer |
|----------|--------|
| Fresh project vs extend menu bar | **Fresh** (this repo). Menu bar (`macos-service/`) stays separate. |
| Python backend fallback | **No.** Core ML only. |
| Voice cloning in v1 | **No.** Use predefined voices. Cloning is v2. |
| ChatLLM backend | **LM Studio** (OpenAI-compatible local API, default `http://localhost:1234/v1`) |
| iOS in v1 | **No.** Possibly v2 after macOS stabilizes. |
| Default voice | TBD — caller's choice. Plan to default to `cosette` until UI persists last-used. |
| Audio export formats | **WAV + AAC + MP3** |

---

## Phase tracking

See `pocket-tts-macos/road-map.md` for the canonical phased plan with hour estimates.

Quick status:

- [x] Phase −1: project bootstrap (Xcode project, git, GitHub remote, road-map, CLAUDE.md)
- [x] Phase 0a — voice KV state precompute: 7 voices exported to `/Users/system-backup/dev_local/pocket-tts-core-ml-conversion/voice_kv_states/*.safetensors` (T_voice 125–161 per voice)
- [x] Phase 0b — `prompt_phase.mlpackage` converted, 140 MB, validated against PyTorch at 1.84% worst K rel-err (passing 5% threshold). Notable: ANE compile rejects multi-position SDPA; runs CPU+GPU
- [ ] Phase 0c — Swift engine: Tokenizer, VoiceLoader, TTSEngine + Xcode project scaffolding
- [ ] Phase 0d — end-to-end Swift unit test (text → wav, no Python)
- [ ] Phase 1: streaming audio (StreamingPlayer, WAVEncoder, AAC/MP3 encoder)
- [ ] Phase 2: MVP SwiftUI shell (single-voice mode → v0.1 shippable)
- [ ] Phase 3: MultiTalk + History (SwiftData)
- [ ] Phase 4: LM Studio chat
- [ ] Phase 5: Orb (Metal shader port)
- [ ] Phase 6: polish, signing, notarization, Sparkle, DMG
- [ ] Deferred v2: voice cloning, EnhancementStudio, AudioCompare, iOS variant
