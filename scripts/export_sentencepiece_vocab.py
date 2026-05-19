#!/usr/bin/env python3
"""Export the Kyutai pocket-tts SentencePiece BPE model to a JSON the Swift
runtime can load. Replaces the legacy piece→id-only JSON with one that also
carries per-piece scores (merge priorities) so the Swift tokenizer can do
canonical BPE encoding instead of greedy longest-match.

Output schema:
  {
    "model_type": "BPE",
    "byte_fallback": true,
    "bos_id": 1,
    "eos_id": 2,
    "pad_id": 3,
    "unk_id": 0,
    "pieces": [
      { "id": 0, "piece": "<unk>", "score": 0.0, "type": 2 },
      ...
    ]
  }

`type` values follow the SentencePiece protobuf enum:
  1 = NORMAL,  2 = UNKNOWN,  3 = CONTROL,
  4 = USER_DEFINED, 5 = BYTE, 6 = UNUSED

Run with the pocket-tts venv Python so the sentencepiece package is on path.
"""

import json
import sys
from pathlib import Path

# Use the project's venv if running outside of it.
DEFAULT_VENV = '/Users/system-backup/dev_local/pocket-tts/.venv/lib/python3.10/site-packages'
if DEFAULT_VENV not in sys.path:
    sys.path.insert(0, DEFAULT_VENV)

from sentencepiece import sentencepiece_model_pb2 as model_pb2  # noqa: E402

SP_MODEL = Path('/Users/system-backup/dev_local/pocket-tts-macos/pocket-tts-macos/Resources/tokenizer.model')
OUT_JSON = Path('/Users/system-backup/dev_local/pocket-tts-macos/pocket-tts-macos/Resources/tokenizer_vocab.json')

MODEL_TYPE_NAMES = {0: 'UNIGRAM', 1: 'BPE', 2: 'WORD', 3: 'CHAR'}


def main() -> None:
    m = model_pb2.ModelProto()
    m.ParseFromString(SP_MODEL.read_bytes())

    out = {
        'model_type': MODEL_TYPE_NAMES.get(m.trainer_spec.model_type, 'UNKNOWN'),
        'byte_fallback': bool(m.trainer_spec.byte_fallback),
        'bos_id': m.trainer_spec.bos_id,
        'eos_id': m.trainer_spec.eos_id,
        'pad_id': m.trainer_spec.pad_id,
        'unk_id': m.trainer_spec.unk_id,
        'pieces': [
            {'id': i, 'piece': p.piece, 'score': float(p.score), 'type': int(p.type)}
            for i, p in enumerate(m.pieces)
        ],
    }

    OUT_JSON.write_text(json.dumps(out, ensure_ascii=False, indent=0) + '\n')
    print(f'Wrote {OUT_JSON} ({OUT_JSON.stat().st_size} bytes, {len(out["pieces"])} pieces)')
    print(f'Model type: {out["model_type"]}  byte_fallback: {out["byte_fallback"]}')


if __name__ == '__main__':
    main()
