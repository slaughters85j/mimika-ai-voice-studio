# Phase 10 — Progress Snapshot

Status as of pause point. Track the per-commit bucket of changes so we
can either commit them as-is or roll them together when you return.

## Committed (already in git)

| Commit | SHA | Subject |
|---|---|---|
| C0 | `9d5ec3f` | Phase 10 / Commit 0: Python full-pipeline validator + fixture generator |
| C1 | `5add714` | Phase 10 / Commit 1: Refactor VoiceEnhancer into Engine/LavaSR/ |
| C7 | `dc4fca9` | Phase 10 / Commit 7: Soft-clip the VoiceEnhancer RMS limiter |

## Uncommitted — Bucket "C2": BWE @ 48 kHz + FastLRMerge

Functionally done. All 9 LavaSRFastLRMergeTests pass, including
Pearson ≥ 0.98 parity against the Python reference on all 3 fixtures.
The 6 VoicePipelineTests still pass — no regression. **The biggest
audible quality win in Phase 10 is in this bucket.**

Files:
```
M  scripts/validate_lavasr_enhancement.py   (LR params 4000/256 → 8000/1024;
                                              matches LavaEnhance.load_audio)
M  mimika-ai-voice-studio/Engine/LavaSR/LavaSREnhancerBWE.swift     (SR 44100 → 48000)
A  mimika-ai-voice-studio/Engine/LavaSR/LavaSRFastLRMerge.swift     (NEW)
M  mimika-ai-voice-studio/Engine/LavaSR/LavaSRPipeline.swift        (LR-merge wiring)
A  mimika-ai-voice-studioTests/Helpers/NpyReader.swift              (NEW; .npy + .safetensors helper)
A  mimika-ai-voice-studioTests/LavaSRFastLRMergeTests.swift         (NEW)
```

## Uncommitted — Bucket "C3-partial": 3 of 5 ULUNAS sub-modules

Done in this bucket:

- `LavaSRERB`         — frozen ERB filterbank (analysis `bm` + synthesis `bs`)
- `LavaSRAffinePReLU` — per-channel-per-freq affine + PReLU
- `LavaSRShuffle`     — channel-shuffle for grouped convolutions

All three have passing tests in `LavaSRDenoiserModuleTests`:

- `test_erbBandMerge_matchesPythonReference_studioClean` — Pearson ≥ 0.98 ✓
- `test_erbBandMerge_matchesPythonReference_phoneNoisy`  — Pearson ≥ 0.98 ✓
- `test_erbBandSplit_roundtripIsApproximateIdentity`     — low-band ≤ 1e-5 ✓
- `test_affinePReLU_inRange_smokeTest`                   — math check ✓
- `test_shuffle_preservesShape`                          — shape invariant ✓
- `test_shuffle_interleavesGroups`                       — channel order ✓

NOT done in this bucket (requires bidirectional GRU port — see Risks):

- `LavaSRFA`   — frequency attention via bidirectional GRU
- `LavaSRcTFA` — causal time-freq attention (unidirectional GRU + FA)

Files in C3-partial:
```
A  scripts/export_lavasr_denoiser_weights.py
A  mimika-ai-voice-studio/Engine/LavaSR/LavaSRDenoiserModules.swift
A  mimika-ai-voice-studioTests/LavaSRDenoiserModuleTests.swift
```

## Pending

- **C3-rest**: port `LavaSRFA` + `LavaSRcTFA` (needs bidirectional GRU
  + PyTorch ↔ MLX bias-fusion weight conversion)
- **C4**: `LavaSRXConvBlock`, `LavaSRXDWSBlock`, `LavaSRXMBBlocks`
  (depends on C3 done; also needs BatchNorm2d, ConvTranspose2d, custom
  ZeroPad for causal time padding)
- **C5**: `LavaSRDPGRNN`, `LavaSREncoder`, `LavaSRDecoder`,
  `LavaSRDenoiser` top-level
- **C6**: pipeline wiring + `enableDenoise` toggle
- **C8**: UI copy refresh, README, FIDELITY_BACKLOG close-out
- **C9**: HF upload of `lavasr_denoiser.safetensors` to voice-tools
  bundle, SHA bump in `BundledMLModel.voiceTools.expectedSHA256`

## Sanity-check: full Phase 10 test sweep

```
xcodebuild -scheme mimika-ai-voice-studio -destination 'platform=macOS' \
  -only-testing:mimika-ai-voice-studioTests/VoicePipelineTests \
  -only-testing:mimika-ai-voice-studioTests/VoiceEnhancerSoftClipTests \
  -only-testing:mimika-ai-voice-studioTests/LavaSRFastLRMergeTests \
  -only-testing:mimika-ai-voice-studioTests/LavaSRDenoiserModuleTests \
  test
```

→ 30 / 30 pass cleanly (verified at the pause point).

## Notes for the next pickup

1. **Bidirectional GRU**: MLX-Swift's `GRU` class is unidirectional only.
   The pattern is to instantiate two `GRU`s (forward + reverse), reverse
   the input axis for the second one, run both, then concatenate the
   outputs along the hidden dim. The hidden state shape doubles
   (2H instead of H). The downstream `fc` Linear layer that consumes
   the bidir output already expects `2H` in the PyTorch shapes —
   that's why the upstream Python uses `2C` everywhere after a
   bidir GRU.

2. **PyTorch ↔ MLX GRU weight conversion** — non-trivial because the
   bias conventions differ:
   - PyTorch nn.GRU stores `bias_ih_l0` (input-side, 3H) and
     `bias_hh_l0` (hidden-side, 3H) separately, applied independently
     to r/z/n gates.
   - MLX-Swift GRU merges them into `b` (length 3H, all three gates'
     input-side bias) and `bhn` (length H, only the n-gate's
     hidden-side bias).
   - PyTorch's `bias_hr` and `bias_hz` get folded into MLX's `b[0:2H]`
     by summing with `bias_ih_l0[0:2H]`. Document this in the
     weight-loader.

3. **NpyReader path resolution bug** — I hit one and fixed it: a
   `#filePath` default argument resolves at the *call site*, not the
   function definition. Use a `private static let _selfFilePath = #filePath`
   pattern inside the helper file to anchor relative paths. See
   `NpyReader.phase10FixturesDir()` for the working pattern.

4. **Python venv** for regenerating refs:
   `~/Library/Application Support/pocket-tts-electron/lavasr-venv/bin/python`.
   Three commands:
   ```
   scripts/generate_lavasr_phase10_fixtures.py           # 3 WAVs
   scripts/validate_lavasr_enhancement.py --full         # 18 main refs
   scripts/validate_lavasr_enhancement.py --full --per-stage  # adds module refs
   scripts/export_lavasr_denoiser_weights.py             # safetensors
   ```
   The lavasr_phase10/ fixture dir is gitignored entirely (1.5 MB WAVs +
   ~80 MB .npy + 800 KB .safetensors). All four scripts are idempotent.

5. **Project pattern for MLX Module subclasses with parameterized init**:
   Swift 6 strict-concurrency requires `nonisolated override init()`
   (parameterless) for the override-isolation check, PLUS a separate
   `nonisolated init(params...)` for the real factory. The parameterless
   init creates safe placeholders that the weight loader overwrites.
   Use `nonisolated(unsafe) var` for both modules and parameters
   (NOT `@ParameterInfo` / `@ModuleInfo` — those have property-wrapper
   isolation issues under strict checking).

6. **Weight key remapping**: PyTorch snake_case → Swift camelCase. The
   tests do remapping inline; for production load() in Commit 5 do it
   in the central load method, like `MimiEncoder.swift` (line ~405).
   Sort keys longest-first to avoid prefix-matching bugs.
