#!/usr/bin/env bash
# Sync small bundled assets from the conversion project into the macOS app's
# bundle resources. Manual invocation only — not wired into an Xcode build
# phase to avoid silently re-bundling stale conversion output.
#
# Run from the project root:
#   ./scripts/sync-assets.sh
#
# As of Phase 8, the four heavy `.mlpackage` artifacts (prompt_phase,
# calm_stateful, mimi_stateful, voice_prompt_phase, ~500 MB combined) are
# NO LONGER bundled. They're downloaded on first launch from Hugging Face
# (slaughters85j/pocket-tts-coreml) by `BundledMLModelManager`, verified by
# SHA256, and installed under Application Support. This script only handles
# the small bundled bits now:
#
#   * 7 stock voice KV state files (~5 MB total) — too small to be worth
#     downloading and frequently-referenced in the picker.
#   * tokenizer.model + tokenizer_vocab.json (~1 MB) — needed before any
#     synthesis call can run; not worth a separate download trip.
#
# Sources (read-only; do NOT modify upstream from this script):
#   $CONVERSION_ROOT (env var; defaults to a sibling pocket-tts-core-ml-
#                     conversion/ directory next to this repo):
#     voice_kv_states/        7 stock-voice safetensors files
#     tokenizer_vocab.json    optional (Phase 0c byproduct)
#   ~/.cache/huggingface/hub/models--kyutai--pocket-tts-without-voice-cloning/
#     snapshots/<hash>/tokenizer.model

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES="$PROJECT_ROOT/pocket-tts-macos/Resources"

HF_SNAPSHOT_BASE="$HOME/.cache/huggingface/hub/models--kyutai--pocket-tts-without-voice-cloning/snapshots"

candidate_roots=(
    "${CONVERSION_ROOT:-}"
    "$(cd "$PROJECT_ROOT/.." && pwd)/pocket-tts-core-ml-conversion"
)
CONVERSION_ROOT=""
for candidate in "${candidate_roots[@]}"; do
    if [[ -n "$candidate" && -d "$candidate/voice_kv_states" ]]; then
        CONVERSION_ROOT="$candidate"
        break
    fi
done
if [[ -z "$CONVERSION_ROOT" ]]; then
    echo "error: couldn't locate pocket-tts-core-ml-conversion (set CONVERSION_ROOT env var)" >&2
    exit 1
fi
echo "  using CONVERSION_ROOT = $CONVERSION_ROOT"

# Resolve the HF snapshot hash dynamically (there's only one).
SNAPSHOT_DIR=$(find "$HF_SNAPSHOT_BASE" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [[ -z "$SNAPSHOT_DIR" || ! -f "$SNAPSHOT_DIR/tokenizer.model" ]]; then
    echo "error: tokenizer.model not found under $HF_SNAPSHOT_BASE" >&2
    exit 1
fi

mkdir -p "$RESOURCES/voice_kv_states"

# NOTE: as of Phase 8 the four large .mlpackage artifacts (prompt_phase,
# calm_stateful, mimi_stateful, voice_prompt_phase) are downloaded at
# runtime by BundledMLModelManager from huggingface.co/slaughters85j/
# pocket-tts-coreml. They are NOT copied here. If you populated
# Resources/mlpackages/ from a previous run of this script, the bundle
# fallback in ModelPaths means those copies still work — but for a
# clean release you can `rm -rf pocket-tts-macos/Resources/mlpackages`
# to shrink the .app to its new ~50 MB shipping size.

# 1. Voice KV state files — STOCK ONLY (the seven Kyutai voices that
#    ship with the public weights). Custom voices live in the user's
#    sandbox container via the in-app Voice Manager
#    (Application Support/pocket-tts-macos/saved-voices/), never in
#    the source tree. The conversion project may produce more voices,
#    but only the stock seven are safe to bundle in public release
#    binaries.
STOCK_VOICES=(alba azelma cosette fantine javert jean marius)
rm -f "$RESOURCES/voice_kv_states"/*.safetensors
for voice in "${STOCK_VOICES[@]}"; do
    src="$CONVERSION_ROOT/voice_kv_states/$voice.safetensors"
    if [[ ! -f "$src" ]]; then
        echo "error: missing $src" >&2
        exit 1
    fi
    cp "$src" "$RESOURCES/voice_kv_states/"
done
voice_count=$(ls "$RESOURCES/voice_kv_states"/*.safetensors | wc -l | tr -d ' ')
echo "  copied $voice_count stock voice KV files"

# 2. Tokenizer model + vocab JSON (the JSON is what the Swift tokenizer reads;
#    the .model is kept in the bundle for future native-SentencePiece work).
cp "$SNAPSHOT_DIR/tokenizer.model" "$RESOURCES/tokenizer.model"
echo "  copied tokenizer.model from snapshot $(basename "$SNAPSHOT_DIR")"

if [[ -f "$CONVERSION_ROOT/tokenizer_vocab.json" ]]; then
    cp "$CONVERSION_ROOT/tokenizer_vocab.json" "$RESOURCES/tokenizer_vocab.json"
    echo "  copied tokenizer_vocab.json"
else
    echo "warning: tokenizer_vocab.json not found; run scripts/07_export_tokenizer_vocab.py in the conversion project" >&2
fi

# Summary
total_mb=$(du -sh "$RESOURCES" | awk '{print $1}')
echo ""
echo "Resources/ now totals $total_mb"
echo "Done. Build the app — Xcode's synchronized group will auto-include these."
