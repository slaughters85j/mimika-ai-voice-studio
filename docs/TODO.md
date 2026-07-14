# TODO — Work Packages

Working agreement: check this file before starting work; reference the WP# in
commits; a WP is only **Complete** after user validation.

## Current Focus

WP-VIT-1 + WP-VIT-2 are COMPLETE (user-validated) on `revoice-pace-quality` —
ship as v1.5.5 together with the merged `voice-isolation-tuning` work, then
cut the release build for App Store Connect. Remaining open WPs: WP-VIT-3
(in-app editor) and WP-VIT-4 (cleanup).

---

## WP-VIT-1 — Pace-mismatch clipping + WSOLA onset artifacts

**Status:** COMPLETE (user-validated). Five-part fix on
`revoice-pace-quality`: onset guard, WSOLA natural-continuation alignment,
elastic chaining bounded to +0.35 s, best-of-N re-synthesis for takes that
would clip (>1.60× of target, up to 3 takes, keep shortest), and the
paced-target gate (compress toward `min(slot, span + 0.35 s)` so segment ENDS
are bounded like their starts — fixes the year-tail / last-segment drift).
QA loop hardened: early-exit when a finer cap measures worse; a clean first
pass with >10 % drops still gets one refinement attempt. Final measured
state on the 3-speaker test clip: best-on-record across the board —
77 matched / 12 dropped / max 0.70 s / 90th-pct 0.556 s / trend ~0.16 s/min,
zero clip-with-fade events in the kept renders.

RESIDUAL (accepted, documented): on a voice fundamentally ~1.5–2× slower
than the original speaker, the chaining budget saturates at +0.35 s and
overshoots beyond 1.60× still clip (observed up to 3.2×). Bounded chaining
cannot absorb unbounded pace debt — the eventual answer is the per-voice
pace-profiling idea below (warn/steer when a chosen voice can't keep up).

Two coupled problems when the chosen TTS voice speaks slower than the original
speaker:

1. **Clipped words (pace OFF, or overshoot > 1.60×).** When a synthesized
   segment overruns its slot by more than the WSOLA gate cap, the renderer
   falls back to clip-with-fade and genuinely discards words. Measured on a
   3-speaker test clip: `seg 11/15: slot=1.20s synth=2.48s overshoot=2.07x`
   → roughly half the synth cut. This is the main source of truly-missing
   words in re-voiced output.
2. **Scratchy/robotic voice onsets (pace ON).** USER-OBSERVED: WSOLA
   compression makes the FRONT of each re-voiced line sound scratchy and
   robotic, normalizing mid-to-end of the line. Pace ON currently *sounds*
   worse than pace OFF despite measurably tighter timing (Parakeet-native
   max drift 0.40 s vs 0.64 s). Onset transients are where time-compression
   damage is most audible.

Candidate approaches (evaluate, don't assume):
- Onset-protected compression: leave the first ~150–250 ms of each segment
  uncompressed, absorb the ratio in the vowel/steady-state region.
- Better time-scale modification than WSOLA (phase-vocoder family) for
  ratios in the 1.3–2.0× range.
- Upstream fix: faster TTS pacing per segment (if the engine's sampling
  supports a rate control) instead of post-hoc compression.
- Let overshooting segments spill into following silence when the next
  segment is far away (slot already extends to next start; consider
  same-speaker lookahead beyond it).
- Per-voice pace profiling: warn/steer when the chosen voice's natural pace
  is fundamentally incompatible with the original speaker.

Decide the `matchOriginalPace` default AFTER the artifacts are fixed —
currently it's a genuine timing-vs-quality tradeoff the user must pick.

## WP-VIT-2 — Sub-word segmentation polish (gap splits + punctuation)

**Status:** COMPLETE (user-validated — "1983 sounded perfect").
Backward-attach for fragments + punctuation on gap splits, endSec no longer
dragged across silences by punctuation timestamps, and number-run cap
protection with FULL-WORD LOOKAHEAD (Parakeet word-start tokens are usually
word prefixes — "three" arrives as " th"+"ree" — so the number test
assembles the whole incoming word before the wordlist check; diagnosed via
the `[Revoicer.tokens]` raw-token dump added to the QA loop).

The cap split now defers to word-start tokens (done, tested), but GAP splits
can still fragment words, and punctuation tokens with unreliable timestamps
can lead segments (synthetic examples of two observed patterns):
- `compli | cated` — the ASR can emit a >0.3 s timing gap BETWEEN the
  sub-word tokens of one word; the natural gap split then severs it and
  TTS speaks "cated…" as a fragment.
- `. Later that evening` — a sentence-final period token can carry the
  NEXT phrase's timestamp, so a segment starts with stray punctuation.

Fix shape: backward-attach non-word-start tokens on gap splits (append token
to the closing segment, then split before the next word-start token).
CAUTION (found in design): a naive "gap splits only at word starts" rule lets
a segment absorb long silences and swallow the following sentence — the
attach must close the segment immediately, not merely defer the split.

## WP-VIT-3 — In-app video editor (background preservation, the real fix)

**Status:** Idea / not scoped (user-requested, "later")

Programmatic background preservation under re-voiced speech is fundamentally
limited (HTDemucs separates *music*, not ambience entangled with the voice;
the duck experiment was rejected — original-voice bleed is worse than
silence). The user's direction: an in-app editor surface where the separated
tracks (background stem, per-speaker tracks, new voice tracks) are stacked on
a timeline and the user resolves conflicts manually, like Final Cut/Movavi.
Big feature — scope in its own session.

## WP-VIT-4 — Cleanup

**Status:** Not started

- Delete dead `pyannoteClusterDistanceThreshold` + stale pyannote doc
  comments in `DiarizationProvider.swift` (guard the 3 tests that assert on
  it).
- Consider FluidAudio's offline pipeline (KMeans/VBx + extra Core ML models)
  only if force-UP speaker count (splitting into more speakers than detected)
  is ever needed; merge-down covers today's use.

---

## Completed on `voice-isolation-tuning` (pending user validation / merge)

- Change Voices re-entry guard: synchronous `.preparingRevoice` status —
  first click disables the button + shows spinner; rapid taps can't spawn
  duplicate pipelines.
- Sensitivity slider remap: compensates FluidAudio's internal ×1.2, removes
  the >1.0 "never split" dead zone; slider centre preserves stock behavior.
- "Re-detect speakers": diarize-only re-run on cached audio/beds — no full
  pipeline re-run to tune sensitivity/count.
- Post-hoc phantom-speaker merge (auto) + speaker-DB reset per diarize
  (fixes cross-run accumulation).
- "Number of Speakers" made real: agglomerative merge-down to the forced
  count (merge-only; never fabricates speakers).
- Diarization end-pad (+0.5 s clamped) — recaptures VAD-trimmed sentence
  tails (utterance-final words verified captured in STT + render logs).
- Re-voice drift fix: 1.5 s STT segment cap (word-boundary splits only) —
  drift trend 2.31 → ~0.1 s/min, 90th-pct offset 1.50 → 0.28 s (pace on).
- Timing-QA adaptive re-render loop (Parakeet vs Parakeet, dev-log only):
  caps 1.5 → 1.0 → 0.7 s, keeps tightest render; verified catching + fixing
  a 0.72 s drift live.
- Python verification harness `tools/verify_revoice_timing.py` (independent
  Whisper-based cross-check; word-drift plot + dropped-tail report).
- Rejected: background duck under re-voiced speech (0.15 keep) — reverted;
  original-voice bleed judged worse than background silence.
