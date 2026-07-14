#!/usr/bin/env python3
"""
verify_revoice_timing.py — measure lip-sync drift + dropped sentence-tails
between an ORIGINAL clip and its Speaker-Isolator RE-VOICED output.

What it proves (with data, not vibes):
  1. DRIFT: word-level ASR timestamps from both files are aligned by
     content; for every word that survived re-voicing we plot
     (revoiced_time − original_time) vs. original_time. Words from the
     re-voiced speaker accumulate offset; unchanged speakers / background
     stay near 0. Max |offset| ≈ the lip-sync drift you hear.
  2. DROPPED TAILS: words present in the ORIGINAL transcript but absent
     from the re-voiced one — especially utterance-final words — are the
     sentence tails the diarizer cut.
  3. CROSS-CHECK: a transcription-free windowed cross-correlation of the
     two energy envelopes (should sit near 0 globally, confirming the
     files ARE globally synced and the drift is per-speaker, not a bulk
     offset).

Usage:
    python3 tools/verify_revoice_timing.py \
        --original "/path/original_clip.mov" \
        --revoiced "/path/original_clip_re-voiced.mp4" \
        [--model small] [--out ./revoice_timing_report]

Dependencies (install whatever's missing — the script tells you which):
    ffmpeg (CLI)              brew install ffmpeg
    numpy, scipy             pip install numpy scipy
    soundfile                pip install soundfile
    faster-whisper           pip install faster-whisper      (preferred)
       (or) openai-whisper   pip install openai-whisper
    matplotlib (optional)    pip install matplotlib          (for the plot)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, asdict


# --------------------------------------------------------------------------
# Dependency probing — fail loud + helpful, never with a bare ImportError.
# --------------------------------------------------------------------------
def _require(mod: str, pip_name: str | None = None):
    try:
        return __import__(mod)
    except ImportError:
        sys.exit(
            f"[verify] missing Python dependency '{mod}'. Install it:\n"
            f"    pip install {pip_name or mod}"
        )


def _require_ffmpeg():
    if shutil.which("ffmpeg") is None:
        sys.exit("[verify] 'ffmpeg' not on PATH. Install it:\n    brew install ffmpeg")


# --------------------------------------------------------------------------
# Audio extraction
# --------------------------------------------------------------------------
def extract_wav(src: str, dst: str, sample_rate: int = 16000) -> str:
    """ffmpeg → mono 16 kHz PCM WAV (what ASR + the envelope want)."""
    _require_ffmpeg()
    cmd = [
        "ffmpeg", "-y", "-i", src,
        "-vn", "-ac", "1", "-ar", str(sample_rate),
        "-acodec", "pcm_s16le", dst,
        "-loglevel", "error",
    ]
    subprocess.run(cmd, check=True)
    return dst


# --------------------------------------------------------------------------
# Word-level transcription (faster-whisper preferred, openai-whisper fallback)
# --------------------------------------------------------------------------
@dataclass
class Word:
    text: str       # normalized (lowercased, punctuation-stripped)
    raw: str        # original surface form
    start: float
    end: float


_WORD_NORM = re.compile(r"[^a-z0-9']+")


def _norm(w: str) -> str:
    return _WORD_NORM.sub("", w.lower())


def transcribe_words(wav: str, model_size: str) -> list[Word]:
    """Return word-level timed tokens. Tries faster-whisper, then whisper."""
    # --- faster-whisper ---
    try:
        from faster_whisper import WhisperModel
        print(f"[verify] transcribing {os.path.basename(wav)} via faster-whisper ({model_size}, cpu/int8)…")
        model = WhisperModel(model_size, device="cpu", compute_type="int8")
        segments, _info = model.transcribe(wav, word_timestamps=True, vad_filter=False)
        words: list[Word] = []
        for seg in segments:
            for w in (seg.words or []):
                n = _norm(w.word)
                if n:
                    words.append(Word(text=n, raw=w.word.strip(), start=float(w.start), end=float(w.end)))
        return words
    except ImportError:
        pass

    # --- openai-whisper fallback ---
    try:
        import whisper  # type: ignore
    except ImportError:
        sys.exit(
            "[verify] need a Whisper backend for word timestamps. Install one:\n"
            "    pip install faster-whisper      (preferred — faster)\n"
            "    pip install openai-whisper"
        )
    print(f"[verify] transcribing {os.path.basename(wav)} via openai-whisper ({model_size})…")
    model = whisper.load_model(model_size)
    result = model.transcribe(wav, word_timestamps=True, fp16=False)
    words = []
    for seg in result.get("segments", []):
        for w in seg.get("words", []):
            n = _norm(w["word"])
            if n:
                words.append(Word(text=n, raw=w["word"].strip(),
                                  start=float(w["start"]), end=float(w["end"])))
    return words


# --------------------------------------------------------------------------
# Content alignment (difflib on the normalized word streams)
# --------------------------------------------------------------------------
@dataclass
class Match:
    word: str
    orig_start: float
    revo_start: float
    offset: float      # revo_start - orig_start  (>0 ⇒ new voice is LATE)


def align(orig: list[Word], revo: list[Word]):
    """Sequence-align the two word streams. Returns (matches, dropped, inserted)."""
    from difflib import SequenceMatcher
    sm = SequenceMatcher(a=[w.text for w in orig], b=[w.text for w in revo], autojunk=False)

    matches: list[Match] = []
    dropped: list[Word] = []     # in ORIGINAL, missing from re-voiced (tail loss)
    inserted: list[Word] = []    # in re-voiced, not in original (ASR hallucination)

    ai = bi = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            for k in range(i2 - i1):
                o, r = orig[i1 + k], revo[j1 + k]
                matches.append(Match(word=o.text, orig_start=o.start,
                                     revo_start=r.start, offset=r.start - o.start))
        elif tag == "delete":
            dropped.extend(orig[i1:i2])
        elif tag == "insert":
            inserted.extend(revo[j1:j2])
        elif tag == "replace":
            dropped.extend(orig[i1:i2])
            inserted.extend(revo[j1:j2])
    return matches, dropped, inserted


# --------------------------------------------------------------------------
# Trailing-tail detection: dropped words that ended an utterance in the
# original (a gap >= gap_sec to the next original word follows them).
# --------------------------------------------------------------------------
def trailing_drops(orig: list[Word], dropped: set[int], gap_sec: float = 0.4):
    drops = []
    for idx, w in enumerate(orig):
        if id(w) not in dropped:
            continue
        nxt = orig[idx + 1] if idx + 1 < len(orig) else None
        is_tail = (nxt is None) or (nxt.start - w.end >= gap_sec)
        if is_tail:
            drops.append(w)
    return drops


# --------------------------------------------------------------------------
# Transcription-free cross-check: windowed envelope cross-correlation.
# --------------------------------------------------------------------------
def envelope_lag_curve(orig_wav: str, revo_wav: str, win_sec=12.0, hop_sec=6.0):
    np = _require("numpy")
    sf = _require("soundfile")
    from scipy import signal  # noqa: triggers a clear error if scipy missing

    def env(path):
        x, sr = sf.read(path)
        if x.ndim > 1:
            x = x.mean(axis=1)
        # 25 ms RMS frames → coarse energy envelope @ 100 Hz.
        fr = int(sr * 0.025)
        hop = int(sr * 0.010)
        n = 1 + (len(x) - fr) // hop if len(x) >= fr else 0
        e = np.empty(n, dtype=np.float64)
        for i in range(n):
            seg = x[i * hop:i * hop + fr]
            e[i] = np.sqrt(np.mean(seg * seg) + 1e-12)
        return e, 100.0  # envelope sample rate (Hz)

    eo, fps = env(orig_wav)
    er, _ = env(revo_wav)
    win = int(win_sec * fps)
    hop = int(hop_sec * fps)
    max_lag = int(6.0 * fps)  # search ±6 s
    curve = []
    i = 0
    while i + win <= min(len(eo), len(er)):
        a = eo[i:i + win] - eo[i:i + win].mean()
        b = er[i:i + win] - er[i:i + win].mean()
        xc = signal.correlate(b, a, mode="full")
        lags = signal.correlation_lags(len(b), len(a), mode="full")
        m = np.abs(lags) <= max_lag
        best = lags[m][np.argmax(xc[m])]
        curve.append((round((i + win / 2) / fps, 2), round(best / fps, 3)))
        i += hop
    return curve


# --------------------------------------------------------------------------
# Reporting + plot
# --------------------------------------------------------------------------
def percentile(vals, p):
    if not vals:
        return 0.0
    s = sorted(vals)
    k = (len(s) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(s) - 1)
    return s[f] + (s[c] - s[f]) * (k - f)


def main():
    ap = argparse.ArgumentParser(description="Measure re-voice lip-sync drift + dropped tails.")
    ap.add_argument("--original", required=True)
    ap.add_argument("--revoiced", required=True)
    ap.add_argument("--model", default="small", help="whisper model size (tiny/base/small/medium)")
    ap.add_argument("--out", default="./revoice_timing_report", help="output dir for plot + json")
    args = ap.parse_args()

    for f in (args.original, args.revoiced):
        if not os.path.isfile(f):
            sys.exit(f"[verify] file not found: {f}")
    os.makedirs(args.out, exist_ok=True)

    tmp = tempfile.mkdtemp(prefix="revoice_verify_")
    orig_wav = extract_wav(args.original, os.path.join(tmp, "orig.wav"))
    revo_wav = extract_wav(args.revoiced, os.path.join(tmp, "revo.wav"))

    orig_words = transcribe_words(orig_wav, args.model)
    revo_words = transcribe_words(revo_wav, args.model)
    print(f"[verify] words: original={len(orig_words)}  revoiced={len(revo_words)}")

    matches, dropped, inserted = align(orig_words, revo_words)
    dropped_ids = {id(w) for w in dropped}
    tails = trailing_drops(orig_words, dropped_ids)

    offsets = [m.offset for m in matches]
    abs_off = [abs(o) for o in offsets]

    print("\n================ DRIFT (lip-sync) ================")
    if matches:
        # Drift trend: fit offset = a*t + b over matched words.
        np = _require("numpy")
        t = np.array([m.orig_start for m in matches])
        y = np.array(offsets)
        a, b = np.polyfit(t, y, 1) if len(matches) >= 2 else (0.0, 0.0)
        print(f"  matched words:          {len(matches)}")
        print(f"  median |offset|:        {percentile(abs_off,50):.3f} s")
        print(f"  90th-pct |offset|:      {percentile(abs_off,90):.3f} s")
        print(f"  MAX |offset|:           {max(abs_off):.3f} s   <-- the worst lip-sync gap")
        print(f"  drift trend:            {a*60:.2f} s per minute  (slope of offset vs time)")
        # Where the worst drift lands:
        worst = max(matches, key=lambda m: abs(m.offset))
        print(f"  worst word:             '{worst.word}' @ orig {worst.orig_start:.1f}s → revo {worst.revo_start:.1f}s "
              f"(offset {worst.offset:+.2f}s)")
    else:
        print("  no matched words — transcripts diverged completely (check model/quality).")

    print("\n================ DROPPED SENTENCE TAILS ================")
    print(f"  total original words dropped from re-voiced: {len(dropped)}")
    print(f"  of those, utterance-FINAL (trailing tails):  {len(tails)}")
    for w in tails[:25]:
        print(f"    [{w.start:7.2f}–{w.end:6.2f}s]  '{w.raw}'")
    if len(tails) > 25:
        print(f"    … +{len(tails)-25} more")

    print("\n================ CROSS-CHECK (envelope lag) ================")
    try:
        curve = envelope_lag_curve(orig_wav, revo_wav)
        lags = [l for _, l in curve]
        if lags:
            print(f"  windowed lag: median={percentile([abs(x) for x in lags],50):.2f}s "
                  f"max={max(abs(x) for x in lags):.2f}s")
            print("  (near-0 globally = files ARE synced; per-WORD drift above is the re-voiced speaker)")
    except SystemExit:
        raise
    except Exception as e:
        curve = []
        print(f"  (skipped: {e})")

    # ---- persist data ----
    data = {
        "original": args.original,
        "revoiced": args.revoiced,
        "model": args.model,
        "n_matched": len(matches),
        "n_dropped": len(dropped),
        "n_trailing_tails": len(tails),
        "max_abs_offset_sec": max(abs_off) if abs_off else 0.0,
        "median_abs_offset_sec": percentile(abs_off, 50),
        "matches": [asdict(m) for m in matches],
        "trailing_tails": [{"word": w.raw, "start": w.start, "end": w.end} for w in tails],
        "envelope_lag_curve": curve,
    }
    json_path = os.path.join(args.out, "report.json")
    with open(json_path, "w") as fp:
        json.dump(data, fp, indent=2)
    print(f"\n[verify] data → {json_path}")

    # ---- plot ----
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(2, 1, figsize=(12, 8), sharex=True)
        if matches:
            ax[0].scatter([m.orig_start for m in matches], offsets, s=8, alpha=0.5, label="per-word offset")
            ax[0].axhline(0, color="k", lw=0.6)
            ax[0].set_ylabel("revoiced − original (s)")
            ax[0].set_title("Lip-sync drift per word (positive = new voice is late)")
            ax[0].legend(loc="upper left")
        if curve:
            ax[1].plot([t for t, _ in curve], [l for _, l in curve], marker="o", ms=3)
            ax[1].axhline(0, color="k", lw=0.6)
        ax[1].set_ylabel("envelope lag (s)")
        ax[1].set_xlabel("time in clip (s)")
        ax[1].set_title("Cross-check: global envelope lag")
        for w in tails:
            ax[0].axvline(w.start, color="r", alpha=0.15)
        png = os.path.join(args.out, "drift.png")
        fig.tight_layout()
        fig.savefig(png, dpi=120)
        print(f"[verify] plot → {png}  (red lines = dropped sentence tails)")
    except ImportError:
        print("[verify] matplotlib not installed — skipped plot (pip install matplotlib)")

    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
