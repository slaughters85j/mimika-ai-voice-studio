# CLAUDE.md

Single-shot context for any Claude Code session working in this repo. Read first.

> **Note:** This file is intentionally checked in (no symlink trick) so the project is self-contained for fresh sessions.

---

## Project Overview

**pocket-tts-macos** is a native Swift / SwiftUI macOS app that replaces the existing Electron-based pocket-tts frontend with a fully on-device, Python-free TTS application. It runs the Kyutai pocket-tts model end-to-end via Core ML `.mlpackage` artifacts (CaLM + Mimi codec), with no Python server, no PyInstaller bundle, and no network dependency for synthesis.


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
├── AGENTS.md                          ← this file
├── pocket-tts-macos.xcodeproj/
├── pocket-tts-macos/
│   ├── road-map.md
│   ├── App/
│   │   ├── PocketTTSMacOSApp.swift   (@main)
│   │   ├── AppState.swift            (global app state + engine ownership)
│   │   └── SynthesisStatus.swift
│   ├── Models/
│   │   ├── BundledVoice.swift        (stock voice catalog entry)
│   │   └── ChatModels.swift
│   ├── Engine/
│   │   ├── TTSEngine.swift           (Core ML synthesis orchestrator)
│   │   ├── TTSEngineProtocol.swift   (testable engine surface)
│   │   ├── Tokenizer.swift           (SentencePiece wrapper)
│   │   ├── VoiceLoader.swift         (safetensors → MLMultiArray)
│   │   ├── VoiceManager.swift        (saved-voices/ catalog + import + orphan recovery)
│   │   ├── FluidAudioSTT.swift         (Parakeet transcription backend)
│   │   ├── SpeakerIsolator.swift     (segment-based speaker extraction)
│   │   ├── SpeakerKitDiarizationProvider.swift
│   │   ├── MultiSpeakerRevoicer.swift
│   │   ├── AudioFileLoader.swift     (decode mono/stereo inputs)
│   │   ├── AudioBuffer.swift
│   │   ├── SourceSeparator.swift     (Phase 7 separation protocol)
│   │   ├── DemucsSourceSeparator.swift
│   │   ├── DemucsChunker.swift
│   │   ├── DemucsModelManager.swift
│   │   ├── DemucsModelInstaller.swift
│   │   ├── DemucsZipExtractor.swift
│   │   ├── DemucsModelVariant.swift
│   │   ├── DemucsStemMap.swift
│   │   ├── DemucsResampler.swift
│   │   ├── SeparatedStems.swift
│   │   ├── VideoMuxer.swift
│   │   └── ModelPaths.swift          (bundle-resource resolution)
│   ├── Audio/
│   │   ├── StreamingPlayer.swift     (AVAudioEngine source node)
│   │   ├── WAVEncoder.swift
│   │   └── AACEncoder.swift          (AVAssetWriter)
│   ├── Persistence/
│   │   ├── DataModels.swift          (SwiftData @Model types)
│   │   ├── AppDataStore.swift
│   │   └── HistoryStore.swift
│   ├── ViewModels/
│   │   ├── SingleVoiceViewModel.swift
│   │   ├── MultiTalkViewModel.swift
│   │   ├── ChatViewModel.swift
│   │   ├── HistoryViewModel.swift
│   │   ├── VoiceChangerViewModel.swift
│   │   ├── SpeakerIsolatorViewModel.swift
│   │   ├── SpeakerIsolatorViewModel+Convert.swift
│   │   ├── SpeakerIsolatorViewModel+ChangeVoices.swift
│   │   ├── SpeakerIsolatorViewModel+Exports.swift
│   │   └── SpeakerIsolatorPipeline.swift
│   ├── Views/
│   │   ├── ContentView.swift         (NavigationSplitView)
│   │   ├── SingleVoiceView.swift
│   │   ├── MultiTalkView.swift
│   │   ├── HistoryView.swift
│   │   ├── ChatView.swift
│   │   ├── VoiceChangerSheet.swift
│   │   ├── SpeakerIsolatorSheet.swift
│   │   ├── DemucsModelManagerSheet.swift
│   │   └── SpeakerIsolator/
│   │       ├── AudioPreservationSection.swift
│   │       ├── DiarizationSettingsPanel.swift
│   │       ├── SeparationProgressLabel.swift
│   │       ├── SeparationStatusBanner.swift
│   │       └── SpeakerRow.swift
│   ├── Components/
│   │   ├── VoiceSelector.swift
│   │   ├── SpeakerCard.swift
│   │   ├── OrbView.swift             (Metal orb)
│   │   ├── StatusIndicator.swift
│   │   ├── PauseModal.swift
│   │   ├── AudioPlayer.swift
│   │   ├── MiniAudioPlayer.swift
│   │   └── SynthesizeButton.swift
│   ├── Networking/
│   │   ├── LocalLLMClient.swift      (OpenAI-compatible local endpoint)
│   │   ├── ScriptGenerator.swift
│   │   └── SentenceDetector.swift
│   ├── Resources/
│   │   ├── mlpackages/
│   │   │   ├── prompt_phase.mlpackage
│   │   │   ├── calm_stateful.mlpackage      (fp32 compute)
│   │   │   ├── mimi_stateful.mlpackage      (fp32 compute, 8192-slot KV cache)
│   │   │   └── voice_prompt_phase.mlpackage (voice-import baker)
│   │   ├── lavasr/                    (voice enhancement resources)
│   │   ├── tokenizer.model
│   │   ├── tokenizer_vocab.json
│   │   └── voice_kv_states/*.safetensors    (stock-only; the 7 Kyutai voices)
│   └── Assets.xcassets/
├── pocket-tts-macosTests/              (XCTest unit tests + fixtures + mocks)
└── pocket-tts-macosUITests/
```

---


## Voice storage — two distinct stores

This trips up every fresh session. Keep them straight:

**Bundled voices (read-only, ship with the app):**
- Location: `pocket-tts-macos/Resources/voice_kv_states/*.safetensors` in source → `.app/Contents/Resources/*.safetensors` in the build
- Type: `BundledVoice` (in `Models/BundledVoice.swift`)
- Catalog: built dynamically by `VoiceLoader.loadAll()` at engine init
- Contents: stock-only — the seven Kyutai voices (`alba`, `azelma`, `cosette`, `fantine`, `javert`, `jean`, `marius`). `sync-assets.sh` is filtered to enforce this.

**Saved voices (user-imported, live in the sandbox container):**
- Location: `~/Library/Containers/<bundle-id>/Data/Library/Application Support/pocket-tts-macos/saved-voices/`
- Type: `Voice` (in `Engine/VoiceManager.swift`)
- Catalog: `voices.json` in the same directory (stores basenames only; paths resolve against the current container at load)
- Files: `<UUID>.wav` + `<UUID>_codes.npy` + `<UUID>_kv.safetensors` + optional `<UUID>_enhanced.wav`
- Managed via the in-app Voice Manager (waveform icon in the header) — never touched by source code

The two stores are surfaced together in pickers but managed separately. **Voices imported via the app NEVER enter `Resources/`** — they're user data, not source. Future agents: don't try to copy custom voices into source; the architecture rejects this by design.

`VoiceManager` runs three on-boot hygiene tasks:
1. **Directory migration** from legacy `fish-voices/` → `saved-voices/` (in-place, idempotent).
2. **Reconcile with disk** — clears stale catalog rows whose files vanished.
3. **Orphan recovery** — surfaces adoptable file triplets (KV + WAV, with parseable KV header) that have no catalog row, in the Voice Manager UI.

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

### SwiftData persistence

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

- ❌ Modify the upstream `pocket-tts` repo ([github.com/slaughters85j/pocket-tts](https://github.com/slaughters85j/pocket-tts)) — read-only reference for the Electron / Python pipeline this app replaced.
- ❌ Modify the `pocket-tts-core-ml-conversion` repo ([github.com/slaughters85j/pocket-tts-core-ml-conversion](https://github.com/slaughters85j/pocket-tts-core-ml-conversion)) except for generating new `.mlpackage`s and validators. The Phase 7 HTDemucs conversion has a separate sibling repo (`pocket-tts-demucs-coreml-conversion`); same rules apply there.
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
| Voice cloning in v1 | **Yes** (shipped in v1.0). Via the in-app Voice Manager → saved-voices/ container. |
| ChatLLM backend | **Local LLM Endpoint** — generic OpenAI-compatible HTTP (LM Studio, Ollama, llama.cpp server, vLLM, LocalAI). Base URL persisted in SwiftData; default `http://localhost:1234/v1`. |
| iOS in v1 | **No.** Possibly v2 after macOS stabilizes. |
| Default voice | TBD — caller's choice. Plan to default to `cosette` until UI persists last-used. |
| Audio export formats | **WAV + AAC + MP3** |

---

## Phase 7 — Speaker Isolation Audio Preservation

Phase 7 adds optional HTDemucs source separation to the Speaker
Isolator so music / SFX / ambient audio can survive underneath
revoiced speech. The user-visible surface is a single "Preserve
background under revoiced speech" toggle in the Audio Preservation
disclosure of the Speaker Isolator sheet, plus a Manage Separation
Models sub-sheet for the explicit 287 MB model download.

**Locked implementation shape (do not regress these):**

- Main app stays Swift / Core ML only. No Python, no PyInstaller, no
  `Process()` shell-out at runtime. The Phase 7 zip extractor is the
  in-process `DemucsZipExtractor` (RFC 1951 raw deflate via Apple's
  `Compression` framework); `/usr/bin/unzip` is test-only.
- HTDemucs ships as a user-downloaded `.mlpackage`. Do NOT vendor the
  ~400 MB weights into the app bundle or test target. The mlpackage
  lives at HF under `slaughters85j/htdemucs-coreml` (MIT, FP32, SHA
  verified on download).
- `DemucsSourceSeparator` MUST load with `.cpuOnly`. GPU / ANE
  dispatch trips the macOS GPU watchdog on HTDemucs's ISTFT graph.
- Speaker Isolator flow is **diarize-first**: load 24 kHz mono, diarize,
  publish initial speakers, THEN (if Audio Preservation is on AND the
  model is installed) load 44.1 kHz stereo, run HTDemucs, re-isolate
  from the vocals stem, append a Background `SpeakerTrack` whose
  `isolatedSamples` is the music stem.
- Missing separator model is a **soft fallback**. With preference on
  but model not installed, run the v1 path + set
  `viewModel.separationFellBackToV1` so the banner surfaces. Do NOT
  auto-download the 287 MB model from `convertAndIsolate`; the user
  installs explicitly via Manage Separation Models.
- The Background row uses the same `SpeakerAssignment` surface as a
  regular speaker (`.useOriginal` + `isolatedSamples` = music stem).
  Do NOT add a `musicStem` parameter to `MultiSpeakerRevoicer.revoice`.
- The post-sum clip in `MultiSpeakerRevoicer` is a PIECEWISE soft-clip:
  identity below the 0.9 knee, tanh-shaped fold above. A global
  `tanh(x * 0.9)` attenuates in-range samples by 10–20% and is a
  regression.

**Review guardrails future agents should re-check:**

- `DemucsSourceSeparator.isModelDownloaded()` must validate a non-empty
  mlpackage dir, not just folder existence. Empty / stale-partial
  placements should fall back, not fail at MLModel load time.
- `DemucsModelManager.modelFolderURL(for:)` mirrors the non-empty
  check; otherwise `download(_:)`'s short-circuit no-ops on empty
  placeholder dirs. Regression-tested by
  `test_downloadDoesNotShortCircuitOnEmptyFolder`.
- Separation progress in `Status.separatingSources(chunk:total:etaSec:)`
  reflects REAL chunk progress + rolling ETA. The separator fires a
  `@Sendable` callback per chunk; the VM hops back to MainActor to
  update Status. A static "chunk 1 of 1" placeholder is a regression.
- "Manage Separation Models…" must remain reachable AFTER the model is
  installed (delete / reveal / manual-placement detection). The Audio
  Preservation section's always-visible `manageModelsLink` covers
  this; do not hide it behind the missing-model CTA only.
- Sheet rescans on appear so manually-placed mlpackages are picked up
  without an app relaunch.

**Implementation file map (live as of Phase 7):**

```
Engine/
  SourceSeparator.swift              ← protocol (separate + model lifecycle)
  SeparatedStems.swift               ← value type (mono 24 kHz vocals + music)
  DemucsStemMap.swift                ← channel layout constants for the [1,8,T] output
  DemucsSourceSeparator.swift        ← actor — chunk-by-chunk inference + edge-aware OLA
  DemucsChunker.swift                ← pure funcs (chunk offsets, triangular window, OLA)
  DemucsResampler.swift              ← AVAudioConverter helpers (mono + stereo)
  DemucsModelManager.swift           ← @MainActor @Observable; SHA, backoff, versioned install
  DemucsModelManagerTypes.swift      ← DownloadState + ManagerError typealiases
  DemucsModelInstaller.swift         ← stateless SHA verify + extract + atomic move
  DemucsZipExtractor.swift           ← in-process zip32 parser (Compression framework)
  DemucsModelVariant.swift           ← variant catalog (just `.htdemucs` for v1)
  BackoffPolicy.swift                ← retry schedule value type

ViewModels/
  SpeakerIsolatorPipeline.swift      ← actor; phase methods for each pipeline step
  SpeakerIsolatorViewModel.swift     ← state + DI; pipeline orchestration in extensions
  SpeakerIsolatorViewModel+Convert.swift       ← convertAndIsolate (diarize-first + sep.)
  SpeakerIsolatorViewModel+ChangeVoices.swift  ← revoice + save flow
  SpeakerIsolatorViewModel+Exports.swift       ← per-row / batch / combined WAV save

Views/SpeakerIsolator/
  DiarizationSettingsPanel.swift     ← extracted from the sheet
  SpeakerRow.swift                   ← extracted from the sheet
  AudioPreservationSection.swift     ← THE toggle + always-visible Manage link + missing-model CTA
  SeparationStatusBanner.swift       ← yellow soft-fallback banner
  SeparationProgressLabel.swift      ← formats .separatingSources for workingLabel
Views/DemucsModelManagerSheet.swift  ← Manage Separation Models sub-sheet
```

---

## Phase tracking

See `pocket-tts-macos/road-map.md` for the canonical phased plan with hour estimates.

Quick status:

- [x] Phase −1: project bootstrap (Xcode project, git, GitHub remote, road-map, CLAUDE.md)
- [x] Phase 0a — voice KV state precompute: 7 voices exported to the conversion repo's `voice_kv_states/*.safetensors` (T_voice 125–161 per voice; not vendored into this repo)
- [x] Phase 0b — `prompt_phase.mlpackage` converted, 140 MB, validated against PyTorch at 1.84% worst K rel-err (passing 5% threshold). Notable: ANE compile rejects multi-position SDPA; runs CPU+GPU
- [x] Phase 0c — Swift engine: Tokenizer, VoiceLoader, TTSEngine + Xcode project scaffolding
- [x] Phase 0d — end-to-end Swift unit test (text → wav, no Python)
- [x] Phase 1: streaming audio (StreamingPlayer, WAVEncoder, AAC/MP3 encoder)
- [x] Phase 2: MVP SwiftUI shell (single-voice mode → v0.1 shippable)
- [x] Phase 3: MultiTalk + History (SwiftData)
- [x] Phase 4: LM Studio chat
- [x] Phase 5: Orb (Metal shader port)
- [ ] Phase 6: polish, signing, notarization, Sparkle, DMG
- [x] Phase 7: Speaker Isolation Audio Preservation (HTDemucs source separation; optional, user-downloaded model)
- [ ] Deferred v2: EnhancementStudio v2, AudioCompare, iOS variant
