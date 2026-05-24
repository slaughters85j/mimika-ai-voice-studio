# Phase 10 — LavaSR full-pipeline port (denoise + 48 kHz BWE + LR-merge)

## Context

The current Swift `VoiceEnhancer` is a partial port. Looking at the actual
upstream Python source (`ysharma3501/LavaSR`, Apache-2.0, the same package
Electron pip-installs from GitHub):

```
LavaEnhance2.enhance(wav, denoise=True):
  Input: 16 kHz mono (utils.load_wav resamples to 16 kHz)
    ↓
  ULUNAS denoiser   ─ 16 kHz mono in / 16 kHz mono out
    ↓                  (denoiser.bin, 803 KB, MIT-licensed)
  resample 16 → 48 kHz
    ↓
  Vocos BWE        ─ 48 kHz in / 48 kHz out
    ↓                  (enhancer_v2/pytorch_model.bin, ~280 MB fp32)
  FastLRMerge      ─ blend: low-freq from upsampled input + high-freq from BWE
    ↓                  (smooths the BWE's "metallic" high-band artifacts;
                       the LavaSR author's own comment in the code)
  Output: 48 kHz mono
    ↓
  (electron resamples 48 → 24 kHz for Mimi; we'll resample to 44.1 kHz
   for Fish DAC or 24 kHz for pocket-tts depending on backend)
```

Our Swift port has **only the BWE step**, plus a couple of correctness bugs
on top:

| Step | Python (Electron) | Swift today | Gap |
|---|---|---|---|
| Denoise | ULUNAS @ 16 kHz | none | **missing entirely** |
| Resample to BWE rate | 16 → 48 kHz | 44.1 kHz direct | **wrong target SR** |
| BWE | Vocos @ 48 kHz | Vocos @ 44.1 kHz | runs out-of-distribution |
| LR-merge | FastLRMerge low+high blend | none | **missing — biggest perceptible quality loss** |
| RMS norm | torch `.clamp(-1, 1)` | Swift hard `min/max` | both hard-clip (minor) |
| `enableDenoise` UI | (separate Python flag) | dead toggle | wired to nothing |

The user-reported "output is worse than input" is the cumulative effect of
all five gaps, with **missing LR-merge** likely the dominant audible cause:
the BWE alone synthesizes the entire 0-Nyquist band including the low
frequencies, where it has nothing useful to add (those frequencies were
already in the input). LR-merge keeps the input's clean low band and only
splices in the BWE's high band, exactly where extension is wanted.

User direction (locked in): treat this as a code-completion problem, not a
model-fit problem. Port the full pipeline; this is a Phase-10-sized effort
(~2-3 weeks).

---

## Approach

### High-level shape

```
Engine/
  VoiceEnhancer.swift                    ← orchestrator, slimmer
  LavaSR/                                ← new sub-folder for the pipeline
    LavaSRPipeline.swift                 ← top-level enhance() coordinator
    LavaSRDenoiser.swift                 ← ULUNAS port (new, ~600 lines)
    LavaSRDenoiserModules.swift          ← ERB, AffinePReLU, cTFA, DPGRNN, Shuffle
    LavaSREnhancerBWE.swift              ← Vocos BWE @ 48 kHz (refactored from
                                            existing LavaSREnhancer)
    LavaSRISTFTHead.swift                ← lifted out of VoiceEnhancer.swift
    LavaSRFastLRMerge.swift              ← Linkwitz-Riley refiner (new, ~80 lines)
    LavaSRResampler.swift                ← thin wrapper around the existing
                                            AVAudioConverter helpers
```

`VoiceEnhancer` becomes the SwiftUI-observable shell: status, lifecycle,
progress reporting, file IO. The audio work moves into `LavaSRPipeline`.

### Weight + asset distribution

- **Denoiser weights** (`denoiser.bin`, 803 KB) — convert PyTorch state dict
  to `lavasr_denoiser.safetensors` via a new `scripts/export_lavasr_denoiser_weights.py`.
  Publish to the existing `slaughters85j/pocket-tts-voice-tools` HF repo
  alongside the BWE weights. Adds <1 MB to the voice-tools bundle.
- **BWE weights** stay as-is (`enhancer_v2_converted.safetensors`, ~280 MB).
- Both pulled by the existing `BundledMLModelManager` voice-tools flow —
  no new runtime download path needed.

### Verification strategy (mandatory, gates every commit)

We have a Python validator script already (`scripts/validate_lavasr_enhancement.py`).
It currently only runs the BWE half. Extend it to drive the FULL Python
`LavaEnhance2` pipeline so we have a ground-truth output. Then every Swift
commit asserts numerical parity against the Python reference on a small
fixture set:

- `lavasr_fixture_studio_clean_8s.wav`     (negative-control: should change least)
- `lavasr_fixture_phone_noisy_8s.wav`      (positive-control: denoiser should help most)
- `lavasr_fixture_webcam_8s.wav`           (middling)

Parity bar:
- **Per-stage** (denoiser-only, BWE-only, LR-merge-only) — Pearson ≥ 0.98
  versus Python at the matching pipeline point.
- **End-to-end** — Pearson ≥ 0.95 (allows for some accumulated drift in
  MLX vs PyTorch ops, e.g., `BatchNorm2d` epsilon, GRU init).
- **Hard fail** under correlation 0.85 at any stage.

---

## Commits

### Commit 0 — Verification harness + Python reference snapshot *(day 1)*

**Goal:** before touching any Swift, generate the ground-truth outputs we'll
test against. If the Python pipeline doesn't reproduce in our environment,
the rest of the plan is blocked.

- Extend `scripts/validate_lavasr_enhancement.py` to call
  `LavaSR.model.LavaEnhance2.enhance(wav, denoise=True)` (the full
  pipeline), not just the BWE.
- Dump per-stage intermediates as numpy `.npy`:
  - `denoiser_input_16k.npy`, `denoiser_output_16k.npy`
  - `bwe_input_48k.npy`, `bwe_output_48k.npy`
  - `lrmerge_output_48k.npy`
  - `final_normalized.npy`
- Commit the 3 fixture WAVs and the 5 reference `.npy` files per fixture
  under `pocket-tts-macosTests/Fixtures/lavasr_phase10/`.
- **Verify:** `python scripts/validate_lavasr_enhancement.py --full`
  exits 0 and produces 15 `.npy` files. Their byte-lengths and dtypes
  match documented expectations.

### Commit 1 — Refactor existing `VoiceEnhancer` into `LavaSR/` sub-folder *(day 2)*

Pure refactor, no behavior change. The existing implementation is a single
391-line file — over the 300-line guideline and growing.

- Split `Engine/VoiceEnhancer.swift` →
  `Engine/VoiceEnhancer.swift` (slim shell, ~120 lines)
  `Engine/LavaSR/LavaSREnhancerBWE.swift` (BWE model + load, ~120 lines)
  `Engine/LavaSR/LavaSRISTFTHead.swift` (ISTFT head, ~120 lines)
  `Engine/LavaSR/LavaSRPipeline.swift` (NEW; placeholder calling only BWE)
- `LavaSRPipeline` exposes the future `enhance(input: [Float], denoise: Bool)` shape;
  the denoise flag is wired but ignored for now (matches current behavior).
- **Verify:** `xcodebuild build` + `VoicePipelineTests.test_enhanceVoice_producesOutputFile`
  passes. No audible change to enhancement output.

### Commit 2 — Switch BWE to 48 kHz + add `FastLRMerge` *(days 3-4)*

This single commit is the most likely candidate for the biggest perceptible
improvement, even before the denoiser ports. Land it first to validate the
parity harness end-to-end.

- `LavaSREnhancerBWE.sampleRate` flips 44100 → 48000.
- Update `AudioPreconditioner.loadMonoFloat32(targetRate: 48_000)` for the
  enhancer code path. Re-validate the per-octave mel filterbank shape
  matches Python at 48 kHz (the config `f_max: 8000` constant stays — only
  the SR changes).
- New `Engine/LavaSR/LavaSRFastLRMerge.swift`:
  ```swift
  struct LavaSRFastLRMerge {
      let sampleRate: Int       // 48000
      let cutoff: Float         // 4000 Hz default
      let transitionBins: Int   // 256

      /// Smoothstep fade template, complex64 in Python — we use Float here
      /// since the magnitude is real and the phase mask is real-valued.
      private let fadeTemplate: [Float]

      /// merged_spec = bweSpec + (inputSpec - bweSpec) * mask
      ///   where mask is 0 below (cutoff - transitionBins/2),
      ///   smoothstep across the transition,
      ///   1 above (cutoff + transitionBins/2)
      func merge(bweTime: MLXArray, inputTime: MLXArray) -> MLXArray { … }
  }
  ```
- Wire `LRMerge` after `bweModel(features)` inside `LavaSRPipeline.enhance(…)`.
- New test `LavaSRFastLRMergeTests`:
  - `testSineWaveLowFreqUnchanged`: 200 Hz sine through merge should pass
    through identically (within 1e-5).
  - `testSineWaveHighFreqFromBWE`: 8 kHz sine in bweTime, silence in inputTime
    → output high-freq sine, no low-freq energy.
  - `testParityAgainstPythonReference`: load `lrmerge_output_48k.npy` from
    Commit 0 fixtures, run Swift merge with the same Commit-0 BWE output,
    assert Pearson ≥ 0.98.
- **Verify:** parity test passes. Manual A/B: re-enhance one of the noisy
  fixture clips, listen to before/after — the metallic-edge artifact in
  the old BWE-only output should be visibly reduced.

### Commit 3 — Port ULUNAS sub-modules: ERB, AffinePReLU, Shuffle, cTFA *(day 5)*

The denoiser depends on five custom layers. Port them in isolation before
the full ULUNAS skeleton so we can test each one independently against
the matching PyTorch op.

- `Engine/LavaSR/LavaSRDenoiserModules.swift`:
  - `ERB` — ERB filterbank (analysis `bm`, synthesis `bs`). Precomputed
    filter banks loaded from weights via `erb.erb_fc.weight` /
    `erb.ierb_fc.weight` (these are saved in `denoiser.bin`).
  - `AffinePReLU` — per-channel-per-freq affine then PReLU. Custom
    parameter shape `(channels, width)`.
  - `Shuffle` — reorder channels for grouped convolutions (`b c g t f -> b (c g) t f`).
  - `cTFA` (causal time-frequency attention) — `GRU(2C) → FC → sigmoid`
    gating along T axis × `FA` block along F axis.
  - `FA` — bidirectional GRU over reshaped frequency window.
- Test each in `LavaSRDenoiserModuleTests`:
  - Random-input forward pass; compare against a per-module Python
    reference saved during Commit 0 (extend the script to dump
    `erb_bm_output.npy`, `affineprelu_output.npy`, etc.).
  - Tolerance Pearson ≥ 0.999 for the deterministic ops (ERB, Shuffle,
    AffinePReLU). ≥ 0.98 for the GRU-based ones (cTFA, FA — float
    precision diffs accumulate).
- **Verify:** all 5 module tests green.

### Commit 4 — Port ULUNAS block types: XConvBlock, XDWSBlock, XMBBlocks *(day 6)*

The encoder/decoder use three different block flavors. All three share the
same ingredients (ConvND, BatchNorm2d, AffinePReLU, cTFA, optional Shuffle)
but compose them differently.

- `Engine/LavaSR/LavaSRDenoiserBlocks.swift`:
  - `LavaSRXConvBlock` (plain conv block; `XConvBlock` in Python)
  - `LavaSRXDWSBlock` (depthwise-separable; pconv → dconv)
  - `LavaSRXMBBlocks` (MobileNet-style; pconv1 → dconv → pconv2 → optional shuffle)
- Custom `nn.ZeroPad2d([0, 0, kt - 1, 0])` for causal time padding ports
  to MLX-Swift's `MLX.padded(_:widths:)` with `[0, kt-1]` on the T axis.
- `nn.ConvTranspose2d` ports to MLX's `ConvTransposed2d`. Watch out for
  `output_padding` — Python omits it (default 0), so we do too.
- Test `LavaSRDenoiserBlockTests`:
  - Per-block forward, compare to Python reference (Commit 0 extension
    dumps `xconv_out.npy`, `xdws_out.npy`, `xmb_out.npy`).
- **Verify:** all 3 block tests green.

### Commit 5 — Port DPGRNN + Encoder + Decoder + ULUNAS top-level *(days 7-8)*

The full denoiser network. Loads weights from `lavasr_denoiser.safetensors`
(which is built from `denoiser.bin` via Commit 0's export script).

- `Engine/LavaSR/LavaSRDenoiser.swift`:
  - `LavaSRDPGRNN` — dual-path GRU (intra-frequency then inter-time, both
    bidirectional, with LayerNorm + residual).
  - `LavaSREncoder` — sequential application of 5 blocks (types
    `[XConvBlock, XMBBlocks, XDWSBlock, XMBBlocks, XDWSBlock]`).
  - `LavaSRDecoder` — mirror with `use_deconv=True`.
  - `LavaSRDenoiser.callAsFunction(_ input: MLXArray) -> MLXArray`:
    - STFT(`n_fft=512, hop=256, win=Hann(512)`), unpack to (B,2,T,F).
    - log10(norm), feed through ERB.bm → encoder → DPGRNN×2 → decoder.
    - Sigmoid mask, ERB.bs back to full bin count, multiply, ISTFT.
    - Zero-pad right end to match input length.
- New `scripts/export_lavasr_denoiser_weights.py` (mirrors the BWE
  exporter): pull `YatharthS/LavaSR/denoiser/denoiser.bin` from HF Hub,
  convert state dict to safetensors. Output: `lavasr_denoiser.safetensors`
  (~803 KB).
- Add `LavaSRDenoiserParityTests`:
  - `testDenoiserMatchesPythonReference`: load 16 kHz fixture, run Swift
    denoiser, assert Pearson ≥ 0.98 versus `denoiser_output_16k.npy`.
- **Verify:** parity test green. Audio file dumped to /tmp/ is audibly
  cleaner than the input fixture.

### Commit 6 — Wire denoiser into `LavaSRPipeline.enhance(…)` *(day 9)*

The pipeline assembly. After this commit Swift's pipeline matches Python's
end-to-end.

- `LavaSRPipeline.enhance(input: AudioBuffer, denoise: Bool) async throws -> [Float]`:
  ```
  let mono16k = resample(input.mono, to: 16_000)
  let denoised = denoise ? denoiser(mono16k) : mono16k
  let mono48k  = resample(denoised, from: 16_000, to: 48_000)
  let bweOut   = bweModel(mono48k)
  let merged   = lrMerge.merge(bweTime: bweOut, inputTime: mono48k)
  return merged
  ```
- `VoiceEnhancer.enhance(inputURL:outputURL:denoise:)` gains the
  `denoise: Bool` parameter (default `true` to match Python). Updates
  `ContentView.onEnhanceVoice` closure to pass the UI value through.
- Wire the dormant `enableDenoise` toggle in `VoiceManagerView` to the
  new pipeline parameter. **First time it actually does something.**
- Add `LavaSRPipelineEndToEndParityTests`:
  - `testFullPipelineMatchesPython_denoiseOn`: Pearson ≥ 0.95 vs
    `final_normalized.npy` (denoise=on case).
  - `testFullPipelineMatchesPython_denoiseOff`: same for denoise=off case.
- **Verify:** both parity tests green. Listen to all 3 fixtures' Swift
  outputs against Python outputs — they should be perceptually identical
  modulo tiny float-precision diffs.

### Commit 7 — Soft clip the RMS limiter *(day 10, 1 hr)*

Lifted directly from Phase 7's `MultiSpeakerRevoicer` fix. Replace:

```swift
return samples.map { min(max($0 * gain, -1.0), 1.0) }
```

with a piecewise soft clip:

```swift
return samples.map { s in
    let scaled = s * gain
    let abs_ = abs(scaled)
    if abs_ <= 0.9 { return scaled }
    let sign = scaled >= 0 ? 1.0 : -1.0
    return Float(sign) * (0.9 + 0.1 * tanh((abs_ - 0.9) / 0.1))
}
```

Add `VoiceEnhancerSoftClipTests`:
- `testInRangeUnchanged`: samples within ±0.85 produce identical output.
- `testOverdriveSoftKnee`: sum past unity rolls off monotonically; never
  hits ±1.0 exactly.

### Commit 8 — UI cleanup: dead toggle removal, copy refresh, mix slider (optional) *(day 11)*

- `VoiceManagerView`:
  - Drop the "until ULUNAS port lands" comment block (no longer true).
  - Update copy: `"Denoise + bandwidth extension. Cleans noise and
    sharpens clarity in one pass. Best for phone, webcam, and older
    recordings."` (replaces the "may introduce artifacts" warning that
    was honest only because of the missing denoiser).
  - Default `enableEnhancement` toggle is now safe to flip to `true` —
    keep it `false` for now and revisit after a user-test pass.
- Optional: add a dry/wet mix slider (matches the Phase-1 plan's
  Path A2, deferred from that earlier proposal). Defer to a follow-up
  if not needed.
- README + FIDELITY_BACKLOG.md update:
  - README: change "ULUNAS port planned" → "ULUNAS denoiser integrated
    via MLX-native port".
  - FIDELITY_BACKLOG: close out P0-L1, P0-L2, P0-L3 (mark `[FIXED]`).

### Commit 9 — Publish denoiser weights to voice-tools HF repo *(day 12, 30 min)*

- Run `python scripts/export_lavasr_denoiser_weights.py` to produce
  `lavasr_denoiser.safetensors`.
- Upload to `slaughters85j/pocket-tts-voice-tools` next to the existing
  `lavasr_enhancer_v2.safetensors`. Bump the repo's manifest SHA (the
  one consumed by `BundledMLModel.voiceTools.expectedSHA256`).
- Update `pocket-tts-macos/Engine/BundledMLModel.swift`:
  ```swift
  case voiceTools:
      // SHA updated for v2 bundle including lavasr_denoiser.safetensors
      return "<new-sha>"
  ```
- Update `ModelPaths.swift` with `lavasrDenoiserWeights()` accessor
  (mirrors `lavasrEnhancerWeights()`).
- Bump app version and tag for the next release (v1.5).

---

## Critical files

### New in main repo

- `Engine/LavaSR/LavaSRPipeline.swift`
- `Engine/LavaSR/LavaSRDenoiser.swift`
- `Engine/LavaSR/LavaSRDenoiserModules.swift` (ERB, AffinePReLU, cTFA, FA, Shuffle)
- `Engine/LavaSR/LavaSRDenoiserBlocks.swift` (XConvBlock, XDWSBlock, XMBBlocks)
- `Engine/LavaSR/LavaSREnhancerBWE.swift` (extracted from existing VoiceEnhancer.swift)
- `Engine/LavaSR/LavaSRISTFTHead.swift` (extracted)
- `Engine/LavaSR/LavaSRFastLRMerge.swift`
- `Engine/LavaSR/LavaSRResampler.swift`

### New tests

- `pocket-tts-macosTests/LavaSRDenoiserModuleTests.swift`
- `pocket-tts-macosTests/LavaSRDenoiserBlockTests.swift`
- `pocket-tts-macosTests/LavaSRDenoiserParityTests.swift`
- `pocket-tts-macosTests/LavaSRFastLRMergeTests.swift`
- `pocket-tts-macosTests/LavaSRPipelineEndToEndParityTests.swift`
- `pocket-tts-macosTests/VoiceEnhancerSoftClipTests.swift`
- `pocket-tts-macosTests/Fixtures/lavasr_phase10/lavasr_fixture_studio_clean_8s.wav`
- `pocket-tts-macosTests/Fixtures/lavasr_phase10/lavasr_fixture_phone_noisy_8s.wav`
- `pocket-tts-macosTests/Fixtures/lavasr_phase10/lavasr_fixture_webcam_8s.wav`
- `pocket-tts-macosTests/Fixtures/lavasr_phase10/*.npy` (15 per-stage references)

### Modified in main repo

- `Engine/VoiceEnhancer.swift` — slim shell. Now just orchestrates
  `LavaSRPipeline`, handles file IO, exposes `@Observable` status.
- `Engine/BundledMLModel.swift` — new SHA for voiceTools v2 bundle.
- `Engine/ModelPaths.swift` — `lavasrDenoiserWeights()` accessor.
- `Engine/AudioPreconditioner.swift` — `loadMonoFloat32(targetRate: 48_000)`
  is now exercised; verify it doesn't regress the existing 44.1 kHz callers.
- `Views/VoiceManagerView.swift` — copy refresh, wire `enableDenoise`.
- `ContentView.swift` — pass `denoise: enableDenoise` through the
  `onEnhanceVoice` closure to `enhancer.enhance(…)`.
- `scripts/validate_lavasr_enhancement.py` — full-pipeline mode + per-stage
  numpy dumps.
- `scripts/export_lavasr_denoiser_weights.py` (new).
- `docs/FIDELITY_BACKLOG.md` — mark P0-L1, P0-L2, P0-L3 fixed.
- `README.md` — drop "ULUNAS port planned" caveat.

### Reused existing patterns

- `AudioPreconditioner` for all resampling — do NOT roll a separate
  resampler in the LavaSR sub-folder; reuse the AVAudioConverter pipeline.
- `BundledMLModelManager` voiceTools flow — denoiser weights ride in the
  existing bundle, no new download path.
- Phase 7's `MultiSpeakerRevoicer` soft-clip — same primitive, mirrored
  into `VoiceEnhancer.rmsNormalize`.
- Phase 0's `MLX.loadArrays(url:)` + `ModuleParameters.unflattened(_:)`
  weight loading.

---

## Verification

### Per-commit gate

```
xcodebuild -scheme pocket-tts-macos -destination 'platform=macOS' build
xcodebuild -scheme pocket-tts-macos -destination 'platform=macOS' \
  -only-testing:pocket-tts-macosTests/VoicePipelineTests \
  -only-testing:pocket-tts-macosTests/LavaSRFastLRMergeTests \
  -only-testing:pocket-tts-macosTests/LavaSRDenoiserModuleTests \
  -only-testing:pocket-tts-macosTests/LavaSRDenoiserBlockTests \
  -only-testing:pocket-tts-macosTests/LavaSRDenoiserParityTests \
  -only-testing:pocket-tts-macosTests/LavaSRPipelineEndToEndParityTests \
  -only-testing:pocket-tts-macosTests/VoiceEnhancerSoftClipTests \
  test
```

### Conversion repo gate

```
source /Users/system-backup/dev_local/pocket-tts/.venv/bin/activate
python scripts/validate_lavasr_enhancement.py --full
python scripts/export_lavasr_denoiser_weights.py
```

### Manual end-to-end after Commit 9

1. Fresh install (delete `~/Library/Application Support/pocket-tts-macos/`),
   first launch → `FirstLaunchSetupView` downloads the voice-tools bundle
   (now ~283 MB instead of ~280 MB). Verify completion.
2. Import a noisy phone recording → toggle "Enhance with LavaSR" ON,
   toggle "Denoise" ON → run. Output WAV should be audibly cleaner AND
   sharper than the input.
3. Same recording, "Denoise" OFF → output WAV should be brighter
   (BWE only) but with the input's noise still present. This verifies
   the toggle is actually wired.
4. A/B against Python-script output saved as `python_enhanced.wav` —
   should be perceptually identical.
5. Import a clean studio recording → enhance → output should NOT sound
   worse than input. Pearson against input ≥ 0.95.
6. Re-enhance a previously-enhanced voice → mid-flow cancel → app
   returns to idle cleanly, no half-written file left behind.

---

## Risks

- **MLX vs PyTorch float-precision drift in GRU layers** — cTFA, FA, DPGRNN
  all stack GRU output, which is the most numerically sensitive piece.
  Mitigation: parity bar at 0.98 not 0.999 for GRU-containing stages.
  If we can't hit 0.98 even with epsilon-perfect math, consider FP32
  forcing on those layers specifically.
- **`BatchNorm2d` inference mode** — running stats baked into weights;
  MLX's `BatchNorm.eval()` semantics need to match PyTorch's
  `track_running_stats=True, training=False`. Easy parity bug if missed.
- **`nn.ZeroPad2d([0, 0, kt-1, 0])`** — causal time padding only on the
  leading edge. MLX uses `[(top, bottom), (left, right)]` per axis;
  pattern requires `widths: [(kt-1, 0), (0, 0)]` on the (T, F) axes.
- **`ConvTranspose2d` output-padding gotcha** — Python's `output_padding`
  parameter defaults to 0; MLX has the same default. Verify nothing
  changes if we leave it off.
- **`einops.rearrange('b t h c -> (b t) h c')`** — collapse + restore
  pattern. MLX doesn't have einops; spell out the reshape/transpose
  sequence and unit-test each.
- **48 kHz audio buffer through `AudioPreconditioner`** — currently no
  caller asks for 48 kHz; we'll need a parity test
  (`AudioPreconditionerStereoTests` already covers 44.1 kHz) to confirm
  the SRC pipeline works at the new target. Add `testLoadMonoFloat32At48kHz`.
- **Weight export reproducibility** — `denoiser.bin` is 803 KB; ensure
  our `.safetensors` is bit-for-bit reproducible across runs (sorted
  keys, deterministic dtype casting). Commit the SHA into
  `scripts/export_lavasr_denoiser_weights.py`'s README block.
- **App Store binary** — does NOT change. The denoiser weights ride in
  the existing voice-tools bundle, downloaded on first launch.
- **First-launch download size** — bumps from ~282 MB to ~283 MB.
  Negligible.

---

## NOT in scope

- Custom denoiser tuning (different noise profiles, learned per-user).
- Per-voice mix slider (Path A2 from the earlier proposal). Defer to a
  v2 if users complain.
- Optional BWE-only mode separated from denoise (the current `enableDenoise`
  toggle handles this).
- Streaming/realtime enhancement.
- Multi-clip batch enhancement.
- Higher-than-48 kHz output paths.
- iOS port.

---

## What already exists / reused

- `Engine/VoiceEnhancer.swift` — existing BWE half + ISTFT head + RMS norm.
  Sliced up in Commit 1, partially rewritten through the rest.
- `Engine/AudioPreconditioner.swift` — covers all the resampling needs;
  no new SRC code.
- `Engine/BundledMLModelManager.swift` — voice-tools download flow,
  re-used unchanged.
- `Engine/ModelPaths.swift` — adds one accessor.
- `scripts/validate_lavasr_enhancement.py` — extend, don't replace.
- `scripts/export_lavasr_weights.py` — pattern template for the new
  denoiser exporter.
- MLX-Swift / MLXAudioCore — already pulled in. `VocosBackbone`,
  `ISTFTHead`, `MLXFFT.rfft/irfft` are all available.
- LavaSR repo (`ysharma3501/LavaSR`, Apache-2.0):
  - `LavaSR/model.py` — pipeline orchestration reference.
  - `LavaSR/denoiser/ulunas.py` — denoiser arch reference (MIT).
  - `LavaSR/enhancer/linkwitz_merge.py` — LR refiner reference (Apache-2.0).
  - `LavaSR/enhancer/enhancer.py` — Vocos BWE wrapper, including the
    monkey-patched custom_forward we already implement.

---

## Worktree parallelization

| Commit | Touches | Depends on |
|---|---|---|
| 0 (Python ref) | `scripts/` + fixtures | — |
| 1 (refactor) | `Engine/VoiceEnhancer.swift`, `Engine/LavaSR/` | — |
| 2 (BWE @ 48k + LR merge) | `LavaSREnhancerBWE.swift`, `LavaSRFastLRMerge.swift` | 0, 1 |
| 3 (denoiser modules) | `LavaSRDenoiserModules.swift` | 0 |
| 4 (denoiser blocks) | `LavaSRDenoiserBlocks.swift` | 3 |
| 5 (ULUNAS top-level) | `LavaSRDenoiser.swift`, exporter | 4 |
| 6 (pipeline wiring) | `LavaSRPipeline.swift`, `VoiceEnhancer.swift`, UI | 2, 5 |
| 7 (soft clip) | `VoiceEnhancer.rmsNormalize` | — |
| 8 (UI cleanup) | `VoiceManagerView.swift`, README, BACKLOG | 6 |
| 9 (publish weights) | HF upload, `BundledMLModel.swift` SHA | 5 |

**Parallel lanes:**
- Lane A (week 1): Commits 0 (Python ref) || 1 (refactor) || 7 (soft clip).
  All independent, can land same day if the validator is reproducible.
- Lane B (week 2): Commits 2 (48k + LR merge) || 3 (denoiser modules).
  Independent; both gated on 0.
- Lane C (week 2): Commit 4 (blocks) depends on 3; Commit 5 (top-level)
  depends on 4. Serial.
- Lane D (week 3): Commit 6 (wiring) depends on 2 + 5. Then 8, 9 in either
  order.

Total wall-clock with parallelism: **2-2.5 weeks for a single developer**.
Sequential without parallelism: **~3 weeks**.

---

## Open question (only one)

The Vocos config explicitly says `sample_rate: 44100`, but the Python
production code runs it at 48 kHz. Is the BWE model actually robust to
out-of-distribution SR? My read of the upstream code is yes — the mel
filterbank is parameterized by `f_min`/`f_max` in Hz, so it works at any
SR ≥ 2 × f_max — but if Commit 2 parity tests come back below 0.95 with
input/output both at 48 kHz, we may need to revert to 44.1 kHz with the
mel filterbank from the safetensors and treat the Linkwitz merge as the
only quality win at the BWE stage. This is a known unknown; the validator
in Commit 0 settles it.

---

## Review decisions baked in (from this conversation)

- **Path:** Phase 0 diagnose first → user opted in.
- **ULUNAS scope:** Include in plan → 6+ days budgeted across Commits 3-5.
- **`enableDenoise` toggle:** Remove, then rebuild — the toggle ships
  wired to a real implementation in Commit 6 instead of being
  removed-and-replaced.
- **Dry/wet mix slider:** Out of scope, can be a v2 follow-up.
- **License posture:** Apache-2.0 (LavaSR + LR merge) + MIT (ULUNAS) are
  both permissive; no license blocker. We retain attribution in source
  headers per each upstream file.
