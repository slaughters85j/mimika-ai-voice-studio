# Pocket TTS macOS — Roadmap

## Project bootstrapping (Phase -1, ~30 min)

- Create Xcode project: macOS app target, SwiftUI lifecycle, Swift 6, min deployment macOS 15 (Core ML stateful requirement)
- Add `pocket-tts-macosTests` target
- SPM deps:
  - `apple/swift-tokenizers` (has SentencePiece)
  - `sparkle-project/Sparkle` (later, for updates)
- **Asset bundling:** drop `mimi_stateful.mlpackage`, `calm_stateful.mlpackage`, `prompt_phase.mlpackage` (Phase 0 output), `tokenizer.model`, and the `embeddings/*.safetensors` into the bundle. ~250 MB final app size, acceptable.
- **Files to port** from `macos-service/PocketTTSMenuBar/Sources/PocketTTSMenuBar/Models/`:
  - `Voice.swift`, `Config.swift` (adapt namespaces; share config dir at `~/Library/Application Support/pocket-tts-electron/` so history migrates)
- **Files NOT to port:** `ServerManager.swift` (no Python), `ConfigManager.swift` (rewrite around SwiftData)

---

## Phase 0 — Foundation (~4–6 hrs)

- `prompt_phase.mlpackage`: extend the Stage 3 work — CaLM wrapper with variable `T_q` input that writes all KV positions in one shot. Same pattern as `calm_stateful`, just batched over input tokens
- `Tokenizer.swift`: thin wrapper over swift-tokenizers `SentencePieceTokenizer`, loads `tokenizer.model` from bundle
- `TTSEngine.swift`: owns `MLModel` handles, `MLState` lifecycles, the prompt → autoregressive loop
- `VoiceLoader.swift`: parses `embeddings/*.safetensors` (small files, simple format) into `MLMultiArray`
- **Acceptance:** Swift unit test — text string → wav file, intelligible, no seed blob

---

## Phase 1 — Streaming playback (~3–4 hrs)

- `StreamingPlayer.swift`: `AVAudioEngine` + `AVAudioSourceNode`, ring buffer fed by `AsyncStream<PCMFrame>` from `TTSEngine`
- `WAVEncoder.swift`: for save-to-disk + history
- **Acceptance:** first audio within ~120 ms of synthesize tap

---

## Phase 2 — MVP UI (~4–5 hrs)

- `PocketTTSApp.swift`, `ContentView.swift` (`NavigationSplitView`)
- `SingleVoiceView`, `VoiceSelector`, `SynthesizeButton`, `AudioPlayer`, `StatusIndicator`, `TextInput`
- Ship-able as **v0.1** here — daily-driver replacement for Electron's primary mode

---

## Phase 3 — Multi-talk + History via SwiftData (~5–6 hrs)

- `DataModels.swift`: `@Model TTSHistoryItem`, `@Model MultiTalkScene` with segment relationships
- View models follow your 10-step pattern (debounced save, `setModelContext`, get/set computed bindings)
- `MultiTalkView`, `SpeakerCard`, `PauseModal`, `HistoryView`
- **Acceptance:** feature parity with Electron's three main tabs

---

## Phase 4 — LM Studio chat (~2–3 hrs)

- `LMStudioClient.swift`: `URLSession` to `http://localhost:1234/v1/chat/completions`, SSE streaming
- `ChatView`: standard chat UI, "speak this reply" button wires into `TTSEngine`
- Settings field for LM Studio URL/port + model name

---

## Phase 5 — Orb (~4–8 hrs, scope-dependent)

- Read `electron/src/renderer/components/Orb.tsx` first — it's a Gemini fractal-orb shader (recent commits)
- Port WebGL/GLSL → Metal MSL, wrap in `MTKView`-backed SwiftUI representable
- Audio-amplitude tap from `AVAudioEngine.mainMixerNode.installTap`
- **Risk:** shader complexity is the unknown — could finish in an afternoon or eat a full day

---

## Phase 6 — Polish & ship (~6–8 hrs)

- Settings pane (voice defaults, LM Studio config, output dir)
- App icon (port from Electron's or generate)
- Code signing + notarization — assumes you have an Apple Developer account; otherwise blocked on that
- Sparkle auto-update + DMG packaging
- Optional: subsume `macos-service` menu bar (or leave standalone)

---

## Timeline summary

**Phase 0–4 cumulative:** ~20 hrs of my work, splittable across 3–4 sessions.

- Ship-able product after **Phase 2** (~12 hrs in)
- Feature-complete after **Phase 5**

---

## Deferred to v2 (~1 full session each)

| Item | Notes |
|------|--------|
| **Voice cloning** | Convert speaker encoder, port `ReferenceAudio` + `SaveVoiceModal`, integrate gated checkpoint. The conversion work is the long pole, ~6–10 hrs |
| **Enhancement Studio + AudioCompare** | Depends on what `voice-enhancer.ts` actually does; need to read it first |
| **iOS variant** | Only after macOS is stable; mostly UI adjustments + `#if os(iOS)` guards since the engine layer is platform-agnostic |
