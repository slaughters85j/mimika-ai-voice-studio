#!/usr/bin/env bash
# Sync Core ML artifacts and voice KV states from the conversion project into
# the macOS app's bundle resources. Manual invocation only — Phase 0c doesn't
# wire this into an Xcode build phase to avoid silently re-bundling stale
# conversion output.
#
# Run from the project root:
#   ./scripts/sync-assets.sh
#
# Sources (read-only; do NOT modify upstream from this script):
#   /Users/system-backup/dev_local/pocket-tts-core-ml-conversion/
#     mlpackages/           prompt_phase + calm_stateful + mimi_stateful
#     voice_kv_states/      34 per-voice safetensors files (padded MAX_SEQ=512)
#   ~/.cache/huggingface/hub/models--kyutai--pocket-tts-without-voice-cloning/
#     snapshots/<hash>/tokenizer.model

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES="$PROJECT_ROOT/pocket-tts-macos/Resources"

CONVERSION_ROOT="/Users/system-backup/dev_local/pocket-tts-core-ml-conversion"
HF_SNAPSHOT_BASE="$HOME/.cache/huggingface/hub/models--kyutai--pocket-tts-without-voice-cloning/snapshots"

if [[ ! -d "$CONVERSION_ROOT/mlpackages" ]]; then
    echo "error: conversion project mlpackages not found at $CONVERSION_ROOT/mlpackages" >&2
    exit 1
fi
if [[ ! -d "$CONVERSION_ROOT/voice_kv_states" ]]; then
    echo "error: voice_kv_states not found at $CONVERSION_ROOT/voice_kv_states" >&2
    exit 1
fi

# Resolve the HF snapshot hash dynamically (there's only one).
SNAPSHOT_DIR=$(find "$HF_SNAPSHOT_BASE" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [[ -z "$SNAPSHOT_DIR" || ! -f "$SNAPSHOT_DIR/tokenizer.model" ]]; then
    echo "error: tokenizer.model not found under $HF_SNAPSHOT_BASE" >&2
    exit 1
fi

mkdir -p "$RESOURCES/mlpackages" "$RESOURCES/voice_kv_states"

# 1. .mlpackage directories (only the three we ship — skip dev artifacts)
for pkg in prompt_phase.mlpackage calm_stateful.mlpackage mimi_stateful.mlpackage; do
    src="$CONVERSION_ROOT/mlpackages/$pkg"
    if [[ ! -d "$src" ]]; then
        echo "error: missing $src" >&2
        exit 1
    fi
    rm -rf "$RESOURCES/mlpackages/$pkg"
    cp -R "$src" "$RESOURCES/mlpackages/"
    echo "  copied $pkg"
done

# 2. Voice KV state files (all of them — VoiceLoader will scan dynamically).
rm -f "$RESOURCES/voice_kv_states"/*.safetensors
cp "$CONVERSION_ROOT/voice_kv_states"/*.safetensors "$RESOURCES/voice_kv_states/"
voice_count=$(ls "$RESOURCES/voice_kv_states"/*.safetensors | wc -l | tr -d ' ')
echo "  copied $voice_count voice KV files"

# 3. Tokenizer model + vocab JSON (the JSON is what the Swift tokenizer reads;
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
