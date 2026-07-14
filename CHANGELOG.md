# Changelog

All notable changes to Mimika (formerly Pocket TTS).

## 1.5.5

Speaker Isolator accuracy + re-voice quality overhaul.

- **Speaker detection you can actually tune** — the Speaker Sensitivity
  slider's dead zone is gone (the full travel now does real work), a new
  "Re-detect speakers" button re-runs detection on the cached audio without
  repeating the slow separation step, phantom duplicate speakers are merged
  automatically, and "Number of Speakers" now genuinely merges the detected
  speakers down to the count you set.
- **Re-voiced speech tracks the original lips** — systematic lip-sync drift
  eliminated (measured ~2.3 s/min → ~0.1 s/min on a 3-speaker test clip, no
  word more than ~0.7 s off): word-aware segment caps, diarization
  end-padding recaptures trailing words, and an internal timing-QA pass
  measures every re-voice and automatically re-renders drifting takes.
- **Cleaner re-voiced audio** — the scratchy, robotic line starts under
  "Match original speaking pace" are fixed (onset-protected compression +
  improved WSOLA alignment); long sentences share their timing slack instead
  of clipping words at chunk boundaries; over-long synthesis takes are
  automatically re-rolled; segment ends are pulled back toward the original
  timing; and years/numbers are never split across synthesis boundaries
  ("nineteen eighty three" stays one utterance).

## 1.5.4

- **Ensemble Mode** (Chat → Ensemble) — you and multiple AI personas hold one
  shared, autonomous, voiced conversation. Cast written by a local LLM or by
  Claude (native structured outputs); Director / round-robin / weighted
  turn-taking with first-name mention addressing; per-speaker sampling presets
  shown as live per-turn badges; an agreement-collapse "grenade" to break a
  stale consensus; rolling-summary context; mic barge-in; export to
  Multi-Talk / History / Markdown.
- **Menu Bar & Read Aloud** — a menu-bar voice picker plus a system-wide
  "Read Selection Aloud" macOS Service: select text in any app, right-click →
  Services (or assign a keyboard shortcut), and Mimika reads it aloud with its
  warm on-device engine. Opt-in, resident menu bar with optional
  launch-at-login. No separate app, server, or Python.

## 1.5.3

- **Record reference audio with your microphone** — live level meter, count-up
  timer, 45-second cap, mono capture; no file needed.
- **Guided script** shown while you record for a better voice match.
- **Listen before you save**, with instant quality tips (too quiet, background
  noise, clipping…).
- Automatic input gain so you can record at a comfortable distance from the mic.

## 1.5.2

- **Rebrand to Mimika** — the app surface was renamed from "Pocket TTS" for
  App Store Guideline 5.2.5 compliance (dropping the "macOS" term and the
  upstream project name). The on-device TTS engine name is unchanged.
- **Audio follows the system default output** — fixed playback being silent
  through AirPods / headphones that became the default output after launch.
  The engine now binds to the current default output device and re-routes
  live when you switch outputs.
- **Fixed an audio-engine priority inversion** around playback teardown — all
  blocking AVAudioEngine lifecycle calls now run on a dedicated serial queue
  at matched QoS, clearing the Thread Performance Checker "Hang Risk".

## 1.5.1

- Fix sidebar layout clipping on short windows.
