# Pocket TTS macOS — Fidelity Backlog

**Source comparison.** `/Users/system-backup/dev_local/pocket-tts` (Python+Electron reference) vs `/Users/system-backup/dev_local/mimika-ai-voice-studio` (native macOS rewrite).

**Scope.** Pocket-TTS backend pipeline only. Fish backend, voice manager, and UI are out of scope for this pass.

**Method.** Read both pipelines end-to-end. For each stage where Python does work, ask whether Swift does the equivalent work. Where it doesn't, write it up. Items are ordered by audible impact, not implementation difficulty.

---

## P0 — Likely the biggest contributors to your "ebb and flow feels off" observation

### P0-1. Default sampling parameters drift

Python defaults (`pocket_tts/default_parameters.py`).
- `DEFAULT_TEMPERATURE = 0.7`
- `DEFAULT_NOISE_CLAMP = None`

Swift defaults (`Engine/TTSEngine.swift`, `SynthesisOptions`).
- `temperature: 0.6`
- `noiseClamp: 4.0`

The noise sampler in Swift uses `std = sqrt(temperature)` (`sampleTruncNormal(std: sqrt(options.temperature), ...)`), so lower temperature plus an active clamp shrinks the latent noise distribution at every AR step. This directly affects the latent variance the CaLM decoder receives, which is exactly the lever the reference uses to set prosodic variability.

Effect on output. Flatter prosody, more monotone delivery, less "natural drift" between sentences. Matches your subjective comparison.

Fix. Match the reference. `temperature = 0.7`, and treat `noiseClamp` as optional (`Float?`); only clamp when non-nil. Confirm the reference's torch `trunc_normal_` call site to make sure "no clamp" in Python actually means "no clamp" and not "clamp at the torch default of `(-2, 2)`".

### P0-2. Sentence chunking uses macOS NLTokenizer, not SentencePiece token counts

Python (`tts_model.py:857 split_into_best_sentences`). Chunks on actual SentencePiece tokens, knows the exact token budget (50 tokens per chunk), groups consecutive sentences into the largest chunk that fits. Sentence boundaries are detected by the SentencePiece end-of-sentence tokens (`.`, `!`, `...`, `?`).

Swift (`TTSEngine.splitForTokenLimit` + `splitIntoSentences`). Uses `NLTokenizer(unit: .sentence)` — Apple's natural-language sentence detector — then greedily checks if each combined chunk fits inside the 128-token model limit by calling `tokenizer.encode(...)` and seeing if it throws. Different sentence detector, different chunk-size budget, different packing math.

Effect on output.
- Different chunk boundaries mean different KV-cache resets, which means different acoustic continuity across sentence joins.
- The token budget mismatch (`50` in Python, `128` in Swift) means the Swift version packs more sentences into a single generation. More sentences per chunk = more cumulative AR error and worse prosody at the back end of long chunks. The Python ceiling of 50 is almost certainly empirically tuned.
- `NLTokenizer` and the Mimi tokenizer disagree on edge cases (ellipses, abbreviations like "Dr.", quoted speech). Different splits → different audio.

Fix. Port `split_into_best_sentences` more literally. Tokenize with SentencePiece, find end-of-sentence token IDs, pack to a 50-token chunk budget. Drop `NLTokenizer`.

### P0-3. `prepare_text_prompt` is not ported

Python (`tts_model.py:824 prepare_text_prompt`). Every chunk goes through this before generation. It does five things that Swift skips entirely.

1. `text.replace("\n", " ").replace("\r", " ").replace("  ", " ")` — collapses whitespace.
2. Computes `frames_after_eos_guess = 3 if ≤4 words else 1` per chunk. Used to control tail generation.
3. Capitalizes first character if not already.
4. Appends `.` if it ends in alphanumeric.
5. **Pads short prompts with 8 leading spaces** when token count is under 5. Comment in source: *"The model does not perform well when there are very few tokens, so we can add empty spaces at the beginning to increase the token count."*

Swift does none of these. `runSynthesisChunk` just hands the normalized text straight to the tokenizer.

Effect on output. Short prompts ("Hi.", "OK.", "Stop.") will sound noticeably worse on Swift because they hit the under-5-tokens degraded regime that Python explicitly works around. The terminal-punctuation guarantee also matters — without it, the model has no clear EOS cue, leading to trailing breath/babble or premature cutoff.

Fix. Port `prepare_text_prompt` verbatim. Apply per-chunk, not per-whole-input. Use the returned `frames_after_eos_guess + 2` as `SynthesisOptions.framesAfterEOS`.

### P0-4. Pause-marker `[Xs]` parsing missing from Single Voice path

Python (`tts_model.py:447 generate_audio_stream`). First operation on every input is `parse_pause_markers(text)`. The function splits text on `[2.5s]`-style markers, returns a list of alternating strings and floats, and the generation loop yields literal silence buffers (`torch.zeros(n_samples)`) for the pause segments. **It also applies 80 ms linear fade-in/fade-out** to the audio chunks immediately before and after each pause to avoid abrupt cuts (`tts_model.py:498`, `fade_samples = int(0.08 * self.sample_rate)`).

Swift. Pause parsing exists in `MultiTalkViewModel` (it inserts `[Xs]` snippets via a modal). It is **completely absent from the Single Voice path**. `SingleVoiceViewModel.synthesize` calls `engine.synthesize(text:voiceID:options:)` directly with the raw text. The normalizer doesn't strip `[Xs]` markers, so they go straight to the tokenizer.

Effect on output.
- Single Voice. Any `[1s]` in the user's input ends up tokenized as something like `[`, `1`, `s`, `]` and the model pronounces fragments of it.
- MultiTalk. Pauses are inserted as silence segments but with no crossfade, so transitions between speech and silence have audible discontinuities.

Fix.
1. Promote `parse_pause_markers` from MultiTalk into a shared `TextNormalizer.parsePauseMarkers` (or `TTSPreprocessor`). Always run it first, before normalization, on both paths.
2. Implement the 80 ms linear fade-in/fade-out around pause segments. Both Single Voice and MultiTalk need this.
3. Pause normalization currently happens in MultiTalk by mapping each segment kind to a player operation. Centralize so both paths share one playback contract.

### P0-5. No crossfade across sentence-chunk boundaries

Python (`tts_model.py:524-560`). Buffers one chunk so the *last* chunk in a multi-sentence segment can have fade-out applied when followed by a pause. Also fades in the *first* chunk after a pause. This is the smoothing that gives the Python output its natural flow at chunk joins.

Swift. None. `runSynthesisChunk` yields PCM frames straight from Mimi with no buffering or fade logic at chunk boundaries.

Effect on output. Audible chunk-boundary artifacts on multi-sentence inputs, especially at the seams where the AR state was reset between chunks. Even subtle level/timbre discontinuities are perceived as the model "stuttering" or "hesitating."

Fix. Match Python's one-chunk buffering pattern in `runSynthesis`. Apply 80 ms cosine or linear fade at the join between chunks of the same segment (gentler than the pause boundary fades, since the model state is preserved across sentences in the same chunk).

---

## P1 — Materially affects pronunciation correctness

### P1-1. Normalizer pipeline misses ellipsis-to-comma when ellipsis is *already* `...`

Python normalizer doesn't do ellipsis substitution at all. The reference relies on the model handling `...` directly.

Swift normalizer first line (`TextNormalizer.swift:21-22`).
```swift
t = t.replacingOccurrences(of: "…", with: ",")
t = t.replacingOccurrences(of: "...", with: ",")
```

This is a deliberate divergence from Python. The Swift author thought it gave better pauses, but the reference uses `...` as an EOS-class token (it's literally in `split_into_best_sentences`'s end-of-sentence token set). Replacing it with `,` **moves it out of the EOS detection path**, which changes where sentences split. That feeds back into P0-2 above and makes the chunking behavior different.

Fix. Remove the substitution. Trust the model. If the resulting pauses are too long, address it at the sampling/decoding side, not by lying to the tokenizer about punctuation.

### P1-2. Normalizer ordering subtly different from Python

Python pipeline order (`text_normalizer.py:907`).
1. Abbreviations
2. List items
3. Currency w/ magnitude
4. Currency simple
5. Percent
6. Time
7. Ordinals
8. Fractions
9. Number+unit
10. Standalone units
11. Standalone numbers
12. Domain (ISR) terms
13. Acronyms
14. Symbols
15. Whitespace cleanup

Swift pipeline order (`TextNormalizer.swift:18-39`). Matches Python's order. Good. **One difference.** Swift does `applyPronunciationFixes` (currently just `Captain → Kaptin`) *before* abbreviations. If "Capt." is in the input, the abbreviation expander turns it into "Captain", then the pronunciation fixer would turn it into "Kaptin" — except the fixer ran first, so it doesn't catch the post-expansion "Captain". Sequence bug.

Fix. Move pronunciation fixes to after abbreviation expansion, or run them twice (pre and post). Consider what pronunciation fixes Python relies on the model handling vs. what the Swift port needs to handle in text.

### P1-3. NumberToWords compounding may diverge from `num2words`

Python uses `num2words` library. Swift has a hand-rolled `NumberToWords.swift`.

Spot differences I noticed.
- Swift uses `"and"` between hundreds and tens ("one hundred and twenty-three"). `num2words` default for English-US does **not** include "and" ("one hundred twenty-three"). British English does. Different output for any 3+ digit number.
- For 4+ digit groups, Swift uses `","` ("one thousand, two hundred"). `num2words` doesn't insert commas in spoken form.
- Decimal handling. Swift says "one point two three" (digit-by-digit after the point). `num2words` default says "one point twenty-three" for short decimals. Worth a side-by-side run.

Fix. Run a battery test that compares NumberToWords output against `num2words` for 0, 1, 21, 100, 101, 123, 1000, 1001, 1234, 1000000, 12345.67, 0.5, -5, etc. Adjust to match Python output exactly.

### P1-4. No `analyze-normalization.py` equivalent in Swift

Python has `scripts/analyze-normalization.py` which compares normalizer output to expected. The Swift side has `TextNormalizerTests.swift` (presumably) but no tool to bulk-diff normalizer output across a corpus.

Fix. Run the Python normalizer and the Swift normalizer on the same corpus (e.g. the test sentences in `tests/test_text_normalizer.py`), diff line-by-line. Anything that doesn't match perfectly is either a known divergence (document it) or a port bug.

### P1-5. List item ordinal capitalization style

Python `_expand_list_item` produces `"First, "` (capitalized + comma + space) from `"1. "`. Good.

Swift `expandListItem` does this:
```swift
return "\(NumberToWords.ordinal(n).prefix(1).uppercased())\(NumberToWords.ordinal(n).dropFirst()), "
```

Calls `ordinal(n)` **twice**. Minor perf issue, not correctness. But Swift's `ordinal(1)` returns `"first"` and the code capitalizes it. Should be functionally the same as Python. Document as verified or test it.

---

## P2 — Smaller correctness gaps

### P2-1. `parse_pause_markers` Python contract not fully matched

Python clamps duration to `[0, MAX_PAUSE_SECONDS]` (10 s) and drops zero-duration pauses entirely. If Swift later ports this, it must match the clamp and the drop. The current `MultiTalkViewModel` pause-insertion uses `String(format: "%.1f", seconds)` for the UI and may not enforce the same bounds at parse time.

### P2-2. Voice loudness normalization differs

Python (`tts_model.py:_normalize_audio_rms`). All audio prompts get RMS-normalized to a configurable target (`rms_target_db`, default `-16 dB`) before encoding.

Swift `FishVoiceManager.rmsNormalizeWAV` does the same target (-16 dB) but applies it *only* on the Fish path and only on import. The `PocketTTSVoiceEncoder.rmsNormalize` does normalize, also at -16 dB.

That's actually consistent for the Pocket-TTS path. Verify nothing in the bundled-voice loading path skips it. Spot-check whether the bundled KV states were originally encoded with the same -16 dB target as the imported voices.

### P2-3. Server-side `crossfade_ms = 100` default for multi-talk

Python (`main.py:173`). MultiTTS endpoint accepts `crossfade_ms` (default 100 ms). Applies via `apply_crossfade(audio1, audio2, crossfade_samples)` — linear crossfade between consecutive speaker segments.

Swift `MultiTalkViewModel`. No crossfade between speakers — segments are played sequentially. Sharp speaker transitions.

Fix. Implement linear or equal-power crossfade in MultiTalk segment assembly. Default 100 ms.

### P2-4. EOS threshold not user-configurable in Swift

Python (`pocket_tts_backend.py:load`). `eos_threshold: float = DEFAULT_EOS_THRESHOLD` (`-4.0`). Wired through to the model.

Swift. EOS detection is baked into the CaLM model output (`is_eos > 0.5` in `runCaLMStep`). The Core ML conversion likely baked in a fixed threshold. The Python knob doesn't exist in Swift.

Fix. Either (a) re-export the CaLM model to expose the raw logits and threshold in Swift, or (b) document this as a deliberate trade — fixed threshold matching whatever the export used. Worth checking the conversion project (`pocket-tts-core-ml-conversion`) to see what threshold got baked in.

### P2-5. `frames_after_eos = +2` adjustment missing in Swift

Python (`tts_model.py:535`). `frames_after_eos_guess += 2` is applied after `prepare_text_prompt` returns its guess. This adds 2 frames of audio after EOS detection on every chunk — 160 ms of trailing audio that smooths the chunk ending.

Swift. `SynthesisOptions.framesAfterEOS: Int = 1`. Fixed at 1, no per-chunk adjustment.

Effect on output. Words that end with sibilants ("fish", "kiss") or unvoiced fricatives lose their tail prematurely. Swift output will sound slightly clipped at sentence ends.

Fix. After porting `prepare_text_prompt`, use its guess + 2 as the per-chunk `framesAfterEOS`.

### P2-6. `lsd_decode_steps` not in Swift

Python (`default_parameters.py`). `DEFAULT_LSD_DECODE_STEPS = 1`. Used in the Mimi decode path.

Swift. Not present. Likely baked into the Mimi Core ML model. Confirm — if the conversion fixed it at 1, this is fine; if it could be tunable, document the trade-off.

---

## P3 — Worth knowing but lower impact

### P3-1. Truncated normal sampler implementation differs

Python uses `torch.nn.init.trunc_normal_(mean=0, std=std, a=-clamp, b=clamp)`. PyTorch's implementation uses inverse-CDF sampling under the hood, which is exact.

Swift `sampleTruncNormal`. Box-Muller for the normal + rejection sampling for the truncation. For a clamp of 4σ this rejects roughly 0.006% of samples, so practically equivalent. For very tight clamps (≤1σ) rejection sampling gets slow. Currently doesn't matter.

Document as "intentional, equivalent at default clamp values."

### P3-2. CaLM/Mimi state copy is a full read+write round trip

Swift `copyOneStateBuffer` reads each KV buffer into a `[Float16]` array, then writes it into the destination state. Six layers × 2 (K and V) = 12 buffers, each 524 288 elements = ~12 MB read + 12 MB write per synthesis call. Python avoids this entirely by sharing the same model state object across phases.

Performance opportunity, not a correctness bug. If `MLState` ever exposes a shared-storage option, use it. Otherwise this is unavoidable Core ML overhead.

### P3-3. Per-platform `POCKET_TTS_NUM_THREADS` env var

Python (`tts_model.py:44`). Honors `POCKET_TTS_NUM_THREADS` or `os.cpu_count()`. Affects PyTorch parallelism.

Swift. Not relevant — Core ML manages its own threading. Document as N/A and move on.

### P3-4. The Electron `tts:generate` IPC supports `rmsTargetDb` per-voice override

Python `main.py:384` accepts `rms_target_db: float = Form(-16.0)`. The Electron app lets the user adjust this per-voice in the Enhancement Studio.

Swift. Per-voice RMS target is stored on `FishVoice` but only used at import. Once imported, the bundled KV state is fixed. No equivalent runtime knob.

Decision needed. Match Python (allow per-synthesis RMS target) or document as "fixed at import."

---

## P4 — Audit findings, not necessarily action items

### P4-1. Pronunciation fixes file has only one entry

`pronunciationFixes` in `TextNormalizer.swift` contains only `Captain → Kaptin`. The reference Python relies on `num2words` and the model's own pronunciation. If you're hearing pronunciation drift on specific words versus the Electron app, build a list and add them here — but with the caveat that the **model itself** is identical, so any pronunciation difference *must* be coming from text-side preprocessing differences, not from the network. Find the text-side cause first.

### P4-2. `spokenAcronyms` set has 3 personal entries (`TARS`, `PSHS`, `GSHS`)

These are program-specific to your QinetiQ work. Python equivalent is loaded from `text_normalizer_local.py` (gitignored) via `SPOKEN_ACRONYMS_LOCAL`. Swift hardcodes them into the source. Functionally fine, but if you ever open-source this you'll want to factor those out the same way Python did.

### P4-3. Test coverage

Python `tests/test_text_normalizer.py` exists. Swift `mimika-ai-voice-studioTests/` has tests but no `TextNormalizerTests.swift` visible in the list I scanned. Should be a parity test that runs the *same fixtures* on both implementations and diffs.

---

## Recommended order of work

1. **P0-1** (one-line fix, immediate audible change).
2. **P0-3** (port `prepare_text_prompt`, ~30 minutes, affects all short utterances).
3. **P0-4** (pause-marker parsing into Single Voice path, plus pause-boundary fades).
4. **P0-2** (sentence chunking via SentencePiece). This is the biggest delta but takes the longest because it touches the tokenizer.
5. **P0-5** (chunk-boundary crossfade).
6. **P1-1** (remove ellipsis substitution).
7. **P1-2** (pronunciation fixes ordering).
8. **P1-3** (`NumberToWords` parity audit).
9. **P1-4** (build the bulk-diff harness — every subsequent change should run through it).
10. Everything else, prioritized by what you actually hear in the side-by-side.

The first three alone should close most of the gap.

---

# Addendum — UX & Subsystem Fidelity

Added 2026-05-18 after side-by-side comparison of the Electron renderer with the SwiftUI views and supporting Metal/MLX subsystems.

## P0 — Orb reactivity

### P0-O1. Orb timebase is wrong by 1000x

Electron (`Orb.tsx:240`):
```ts
plasmaUniforms.uTime.value = timeMs * 0.0004;
```
`timeMs` is milliseconds since RAF start, multiplied by `0.0004`. At 1 s elapsed, `uTime = 0.4`. At 10 s, `uTime = 4`.

Swift (`OrbView.swift:90`):
```swift
time: Float((CACurrentMediaTime() - startTime) * 0.4)
```
`CACurrentMediaTime()` returns **seconds**, not milliseconds. At 1 s elapsed, `time = 0.4`. **Same value.** OK, so the timebase actually matches for the plasma — the comment "match Gemini's slow timebase" works out because of unit conversion.

However the **disc shader on Electron uses a *different* timebase**:
```ts
discMat.uniforms.u_time.value = timeMs / 1000;
```
That is, the disc runs at `timeMs / 1000` = real seconds, **2.5× faster than the plasma**. Swift OrbShader currently uses:
```metal
float discTime = u.time * 2.5;
```
to recover the 2.5× ratio. This appears correct on inspection but should be A/B verified — it's the kind of thing that creeps off by one factor and you can't tell statically.

Fix. Stamp a 10-second video of both orbs side-by-side at idle. If the disc edge warp speeds match, fine. If not, adjust `discTime` multiplier.

### P0-O2. Plasma + disc compositing is fundamentally different

Electron renders **two separate Three.js meshes** with **additive blending** at the framebuffer level. The plasma plane (`THREE.AdditiveBlending`) and the disc circle (`THREE.NormalBlending` with `depthWrite: false` and `renderOrder: 2`) are separate draw calls with their own blend modes.

Swift composites both inside a single fragment shader, using this for the disc:
```metal
col = col + discCol * discAlpha * (1.0 - clamp(length(col), 0.0, 1.0));
```
The plasma uses additive blending in the pipeline state (`sourceRGB=.one, destRGB=.one`), but the **disc is added on top with a non-physical "inverse plasma intensity" attenuation** that has no Electron equivalent. When the plasma is bright (typical case), the disc gets suppressed; when the plasma is dim, the disc shows through. Electron does the opposite — the disc is alpha-blended in its own pass with normal blending, **independent** of plasma brightness.

Effect on output. The Swift orb's disc fades out during loud audio peaks (when plasma intensity rises). The Electron orb's disc stays consistently visible because it's blended in its own pass. This is probably the single biggest reactivity difference you're seeing.

Fix. Either (a) split into two MTKView passes with their own pipeline states matching Electron's blend modes exactly, or (b) drop the `(1.0 - clamp(length(col)...))` attenuation in the single-pass fragment and let the disc add in straightforwardly. Option (b) is the smaller diff; option (a) is the more faithful port.

### P0-O3. Disc scale-with-amplitude has different driver

Electron (`Orb.tsx:248`):
```ts
disc.scale.setScalar(1.0 + smoothAmp * 0.15);
```
Three.js `mesh.scale` applies a **geometric transform** to the disc — its radius literally grows from `0.834` to `~0.959` (15%) at peak amplitude.

Swift (`OrbShader.metal:163`):
```metal
float discScale = 1.0 + u.intensity * 0.1;
effectiveR *= discScale;
```
- Uses `intensity` (which is `0.2 + smoothAmp * 0.8`, **not** raw `smoothAmp`)
- Uses `0.1` (10%), not `0.15` (15%)
- Modifies the SDF radius inside the shader rather than scaling geometry

The math works out differently. With `smoothAmp = 0` (idle): Electron disc = `0.834`, Swift disc = `0.834 * (1 + 0.2*0.1) = 0.834 * 1.02 = 0.851`. So Swift disc is **already 2% bigger at idle**. At peak (`smoothAmp = 1.0`): Electron disc = `0.834 * 1.15 = 0.959`. Swift disc = `0.834 * (1 + 1.0*0.1) = 0.834 * 1.10 = 0.918`. So Swift's peak is **smaller** than Electron's.

Fix.
```metal
float discScale = 1.0 + smoothAmp * 0.15;  // not intensity, not 0.1
```
Means plumbing raw `smoothAmp` into the uniform alongside `intensity`, or computing `(intensity - 0.2) / 0.8` to recover it.

### P0-O4. Smoothing coefficient matches but FFT bin count is fixed

Both use `smoothAmp += (rawAmp - smoothAmp) * 0.20` — same low-pass coefficient. Good.

Electron sums `dataArray[0..64]` from the analyser's `getByteFrequencyData()` then divides by `(fftBins * 255)`. The `64`-bin slice covers roughly DC through 11 kHz at 44.1 kHz with WebAudio's default `fftSize = 2048`.

Swift uses `StreamingPlayer.amplitudeSource`. Not visible in this snippet — needs verification:
- Does the Swift FFT cover the same frequency range?
- Does it use the same number of bins?
- Is the normalization to [0, 1] the same?

If the Swift amplitude source aggregates over a different frequency range (e.g. full spectrum vs. 0–11 kHz, or a different bin count), the orb will react to different parts of the spectrum than Electron does. Voice energy is mostly in 100 Hz–4 kHz; if Swift includes high-band noise, the orb will twitch on consonants and breath rather than tracking voicing.

Fix. Read `StreamingPlayer.swift` and confirm the FFT bin range matches Electron's `fftBins = 64` over 0–11 kHz. If not, narrow it.

### P0-O5. UV aspect-ratio handling differs

Electron uses a `PerspectiveCamera(45, aspect, 0.1, 1000)` with `camera.aspect = w / h` set on resize. The vertex shader gets `position` from a `5×5` plane and the fragment uses `vPosition.xy` directly. **The aspect ratio is handled by the camera projection matrix.**

Swift Metal:
```metal
out.uv = positions[vid] * 2.5;     // scales the [-1,1] NDC quad to [-2.5, 2.5]
// ...
float aspect = u.resolution.x / u.resolution.y;
float2 uv = float2(in.uv.x * aspect, in.uv.y);
```
The Swift port stretches X by aspect ratio. On a 16:9 window the orb gets horizontally stretched into an ellipse. **Worse**, the `dist = length(in.uv)` vignette in the next line uses the **un-stretched** UV, so the falloff is circular while the plasma SDF is elliptical. The orb edges will be cut weirdly on wide windows.

Electron doesn't have this problem because the camera projection handles it correctly.

Fix. Don't stretch UV by aspect. Either:
- Set the orb plane size based on aspect so it fills correctly, or
- Use `min(aspect, 1/aspect)` style logic to keep the orb circular regardless of window aspect ratio.

The cleanest fix: instead of `uv.x *= aspect`, divide by aspect when aspect > 1, leave alone when aspect < 1. Or just pin the orb's effective viewport to a square subregion of the framebuffer.

---

## P1 — Single Voice normalization picker (NOT loudest/quietest — that's MultiTalk)

### P1-N1. Electron Single Voice uses per-voice normalization automatically

The user mentioned a "normalization picker to normalize by the loudest, quietest, and per voice" for Single Voice. **Confirmed in the code, but the picker is actually on MultiTalk**, not Single Voice.

Electron Single Voice (`App.tsx:197-217`). When the user picks a saved voice, `rmsTargetDb` is **automatically pulled from that voice's `audioNormalization.rmsTargetDb`** (set during Enhancement Studio). No picker, no user choice — the per-voice setting just applies.

Electron MultiTalk (`MultiTalk.tsx:72`). **Here** is the picker with three strategies:
- `per_voice` — each speaker uses its own saved `rmsTargetDb`
- `match_quietest` — all speakers normalize to the quietest voice's target
- `match_loudest` — all speakers normalize to the loudest voice's target

Swift state. **Neither feature exists.**

- `Single Voice`. No per-voice RMS target propagation. Bundled voices use whatever was baked at conversion time; imported voices are RMS-normalized to -16 dB **at import** (in `FishVoiceManager.rmsNormalizeWAV`) but there's no way to change that later.
- `MultiTalk`. No normalization strategy picker. Each speaker plays at whatever level the engine emits.

Fix.
1. Persist a `rmsTargetDb` field on imported voices (`FishVoice` struct — easy add since it's already a `Codable`).
2. Add an Enhancement Studio-equivalent UI to adjust this per voice.
3. Single Voice path. Read the voice's saved `rmsTargetDb` and apply to the rendered output (post-engine, since the bundled KV is fixed).
4. MultiTalk path. Add a 3-way picker. Apply the strategy to the per-segment gain before crossfade.

Note. The Swift bundled-voice KV states were baked with their original (probably -16 dB) RMS. Changing RMS post-hoc requires either re-baking the KV (expensive) or applying gain to the output PCM (cheap but the voice prompt's loudness influence is already baked into the model state, so the result won't perfectly match a re-bake). Document this trade-off.

---

## P1 — My Voices section parity

### P1-V1. My Voices not sorted alphabetically

Electron (`VoiceSelector.tsx:114`):
```tsx
{[...savedVoices].sort((a, b) => a.name.localeCompare(b.name)).map(...)}
```
Spread-then-sort by name. Stable alphabetical order regardless of import order.

Swift (`VoiceSelector.swift:46`):
```swift
ForEach(importedVoices) { v in
    Text(v.name).tag("imported:\(v.id)")
}
```
No sort. Order is whatever `FishVoiceManager.voices` returns, which is import order (the order of the `voices.json` array). Adding a voice mid-list puts it at the bottom rather than in alphabetical place.

Fix. One-line sort:
```swift
ForEach(importedVoices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { v in
```
Use `localizedStandardCompare` for Finder-style natural sort (handles "Voice 2" vs "Voice 10" correctly).

Apply this also to the Built-in section. Electron sorts that too (`VoiceSelector.tsx:104`). Swift currently passes `voices.filter { $0.type == .predefined }` straight through with no sort.

### P1-V2. Enhanced voices have no visual indicator

Electron (`VoiceSelector.tsx:116`):
```tsx
{voice.enhanced ? '\u2728 ' : ''}{voice.name}
```
The `\u2728` is ✨ (sparkle emoji). Enhanced voices show a sparkle before the name in the dropdown. Easy to scan visually.

Swift. No equivalent. Enhanced voices look identical to non-enhanced ones in the picker.

Fix. Add an `enhanced: Bool` flag to `FishVoice` (or detect via the existence of an enhanced asset). Prepend ✨ to the picker text:
```swift
Text(v.enhanced ? "✨ \(v.name)" : v.name).tag("imported:\(v.id)")
```

Note. Swift's `FishVoice` struct doesn't currently track enhancement state. The `VoiceEnhancer.enhance` writes back to the same URL, so the original gets overwritten. Add a separate `enhancedURL: URL?` field, OR add a boolean `wasEnhanced`, OR keep a backup like Electron does and infer from its existence.

### P1-V3. No per-voice "Enhanced (-14 dB)" badge with RMS level

Electron also shows the RMS target dB as a badge next to enhanced voices when selected (`VoiceSelector.tsx:140`). Lower priority — depends on P1-N1 landing first since this just surfaces the value.

### P1-V4. No "Enhance with LavaSR" / "Edit Enhancement" button in Swift selector

Electron offers in-line buttons:
- `Enhance with LavaSR` for voices that haven't been enhanced yet
- `Edit Enhancement` to revisit settings for already-enhanced voices
- `Delete` to remove a saved voice
- Setup progress indicator if LavaSR needs to be downloaded first

Swift Voice Selector has none of these. Voice management is gated to the Voice Manager modal. Functional but a worse UX for the common "enhance the voice I just picked" path.

Fix. Consider hoisting the enhance action into the picker context menu or as an inline action button when a saved voice is selected.

---

## P0 — LavaSR is a fundamentally different model

### P0-L1. Swift port reimplemented only the BWE component, not the full LavaSR pipeline

Python (`electron/resources/enhance-voice.py:80`):
```python
from LavaSR.model import LavaEnhance2
model = LavaEnhance2("YatharthS/LavaSR", device)
input_audio, input_sr = model.load_audio(input_path)
output_audio = model.enhance(input_audio, denoise=denoise, batch=False)
```
**Uses the original LavaSR repo's `LavaEnhance2` class directly.** This is the full pipeline with:
- The **ULUNAS denoiser** front-end (cleans noise/reverb)
- The **BWE (bandwidth extension)** back-end (Vocos-based 24 kHz → 48 kHz upsampling)
- Native 48 kHz output (then resampled to 24 kHz for Mimi)

Swift (`VoiceEnhancer.swift:5-9`):
```swift
//  LavaSR v2 voice enhancement via MLX. Uses the Vocos BWE (bandwidth
//  extension) model to improve voice recording quality for TTS cloning.
//  Reuses VocosBackbone + ISTFTHead from mlx-audio-swift.
//
//  The ULUNAS denoiser is not ported yet — only the BWE enhancer runs.
//  Most reference recordings are clean enough without denoising.
```

**Explicitly admits the denoiser is missing.** The Swift port is a partial reimplementation of the back half of the pipeline only.

Also: Swift runs at **44.1 kHz** (`LavaSREnhancer.sampleRate = 44100`). Python's LavaSR runs at **48 kHz** native, resampled to 24 kHz for Mimi. Different sample rate means different mel filterbank spacing, different STFT framing, different overall frequency response.

Effect on output. Three compounding problems.
1. **No denoising.** Recordings with any background noise (room tone, HVAC, mic self-noise) will sound *worse* after Swift's BWE-only "enhancement" because it amplifies high frequencies including the noise. Electron denoises first, then extends.
2. **Wrong sample rate.** Mel filterbank mismatch means spectrograms encode different frequency content than the original LavaSR was trained on.
3. **Possibly incomplete BWE weights.** Comment says "LavaSR v2 weights" — verify these are the same checkpoint that `LavaSR.model.LavaEnhance2` uses. The conversion script (`scripts/export_lavasr_weights.py`) needs an audit.

Fix options, in order of effort.
1. **Disable the Swift LavaSR until the full model is ported.** Show the user a "Enhancement requires the desktop version" message. Avoids producing degraded audio.
2. **Port the ULUNAS denoiser to MLX.** The denoiser is itself a learned model with weights — find the source repo, audit architecture, port. Probably weeks of work.
3. **Bundle a Python sidecar.** Electron's approach. Ships a `lavasr-venv` and shells out to `enhance-voice.py`. Goes against the project's "fully native, no Python" goal but is by far the lowest-effort way to match Electron's quality. Worth a discussion.
4. **Switch to a different enhancement model entirely.** Apple's `AVAudioEngine` has built-in noise reduction; combined with a smaller, fully-ported BWE could be acceptable. Different sound profile from Electron though.

### P0-L2. The sample rate change breaks compatibility with Mimi

Python pipeline:
```
Voice WAV → LavaSR @ 48 kHz → resample to 24 kHz → Mimi encode at 24 kHz
```

Swift pipeline:
```
Voice WAV → LavaSR @ 44.1 kHz → ??? → MimiEncoder
```

Mimi is **fixed at 24 kHz native**. The Swift `MimiEncoder` presumably resamples the 44.1 kHz LavaSR output. Two questions worth answering:
- Does that resample happen? Where? Is it correct?
- Why 44.1 kHz and not 48 kHz to match Python? If the LavaSR weights were trained at 48 kHz and Swift runs them at 44.1 kHz, the model is being run **out of distribution**.

Audit needed. Trace the post-enhancement WAV from `VoiceEnhancer.writeWAV(samples:sampleRate:url:)` through the rest of the import pipeline and confirm what sample rate the Mimi encoder sees. If the answer is "44.1 kHz then resampled to 24 kHz" but `enhancer_v2_converted.safetensors` was trained at 48 kHz, that's a model-input mismatch in addition to the missing denoiser.

### P0-L3. RMS normalization happens at a different stage

Python (`enhance-voice.py:115`). RMS-normalize the **enhanced** audio to `rms_target_db` if provided, **before** writing to disk. This becomes the "loudness contract" of the saved voice file.

Swift. RMS-normalize to `-16.0 dB` hardcoded, **after** enhancement, in `VoiceEnhancer.enhance`. The hardcoded -16 matches Python's default but loses the per-voice tuning.

Plus, see P1-N1: there's no UI to change this from -16 even if you wanted to. Once persistent voice metadata supports per-voice `rmsTargetDb` (P1-N1 fix), the enhancer should use it instead of the hardcoded constant.

---

## Updated recommended order of work

Given the breadth of P0 items, the original 1–10 ordering needs revision. Two parallel tracks:

**Track A: TTS quality (audible immediately)**
1. P0-1 (sampling defaults, temperature 0.7, no noise clamp)
2. P0-3 (`prepare_text_prompt` port)
3. P0-4 (pause markers in Single Voice path)
4. P0-2 (proper SentencePiece chunking)
5. P0-5 (chunk-boundary crossfade)

**Track B: UX and feature parity**
1. P1-V1 (sort My Voices alphabetically — 5 minute fix)
2. P0-O5 (orb aspect ratio — visible on wide windows)
3. P0-O2 (orb plasma/disc blending — visible on every audio peak)
4. P0-O3 (disc scale-with-amplitude — easy fix, more accurate reactivity)
5. P1-V2 (sparkle for enhanced voices)
6. P1-N1 (per-voice normalization plumbing)
7. P0-L1 decision (Swift LavaSR is too broken to ship as-is — pick a fix path)

Track B's items 1–5 are all small, fast fixes. Worth knocking them out in a single sitting before going deep on the larger Track A items.
