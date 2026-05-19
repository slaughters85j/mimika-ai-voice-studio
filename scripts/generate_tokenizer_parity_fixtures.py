#!/usr/bin/env python3
"""Generate parity test fixtures for the Swift SentencePiece tokenizer.

Emits a JSON file the Swift unit test loads to verify that Swift's Viterbi
encoder produces byte-identical token IDs to canonical SentencePiece for a
representative set of English inputs.

Fixture schema:
  [
    { "text": "...", "expected_ids": [int, ...] },
    ...
  ]

Re-run whenever the test corpus or tokenizer.model changes. The Swift test
will fail loudly if any case drifts."""

import json
import sys
from pathlib import Path

sys.path.insert(0, '/Users/system-backup/dev_local/pocket-tts/.venv/lib/python3.10/site-packages')

import sentencepiece as spm

SP_MODEL = '/Users/system-backup/dev_local/pocket-tts-macos/pocket-tts-macos/Resources/tokenizer.model'
OUT = Path('/Users/system-backup/dev_local/pocket-tts-macos/pocket-tts-macosTests/Fixtures/tokenizer_parity.json')

# Test corpus. Covers:
#   - The specific words user reported broken (friends, perfect)
#   - Common English with capitalization variants
#   - Punctuation including the '...' case that distorts on greedy
#   - Numbers, mixed alphanumeric, hyphenation
#   - The Rainbow Passage sentences (voice cloning standard)
#   - Edge cases (empty, single character, leading/trailing space)
TESTS = [
    # Single-word regressions
    'friends',
    'Friends',
    'perfect',
    'Perfect',
    'speakers',
    'extraordinarily',
    'disestablishmentarianism',

    # Short phrases
    'my friends',
    'good friends',
    'best friends forever',
    'a perfect day',
    'perfect storm',
    'speakers and friends',
    'Hello, world.',
    "Don't worry about it.",

    # Punctuation edge cases (the '...' bug from user testing)
    'And as for Worf... well, he is good.',
    'Wait... what?',
    'one two three... four.',
    'Yes... no... maybe.',

    # Numbers / mixed
    'mixed: 123 numbers and words',
    'I have 5 apples and 12 oranges.',
    'It is 3:30 PM on Tuesday.',
    'The year 2026 is going well.',

    # Hyphenated / capitalized acronyms
    'Welcome to the Pocket-TTS system.',
    'NASA launched a rocket.',
    'My friend works at IBM.',

    # Rainbow Passage (voice-cloning gold standard)
    'When the sunlight strikes raindrops in the air, they act as a prism and form a rainbow.',
    'The rainbow is a division of white light into many beautiful colors.',
    'These take the shape of a long round arch, with its path high above, and its two ends apparently beyond the horizon.',
    'There is, according to legend, a boiling pot of gold at one end.',
    'People look, but no one ever finds it.',
    'When a man looks for something beyond his reach, his friends say he is looking for the pot of gold at the end of the rainbow.',

    # Classic pangrams
    'The quick brown fox jumps over the lazy dog.',
    'Pack my box with five dozen liquor jugs.',
    'It was the best of times, it was the worst of times.',
    'The rain in Spain falls mainly on the plain.',

    # Edge cases
    '',
    'a',
    'I',
    'A',
    ' leading space',
    'trailing space ',

    # Apostrophe / contraction regressions (user-reported distortion cases).
    # Add the literal failing phrases plus a few more contraction variants
    # so a tokenizer drift on any of them surfaces here loudly.
    "let's",
    "C'mon",
    "She's",
    "it's not working",
    "I'm fine",
    "can't",
    "won't",
    "they're",
    "we'll",
    "you've",
    "While I appreciate the enthusiasm, let's keep things respectful.",
    "Well, let me tell you something, pal: it's not working!",
]

sp = spm.SentencePieceProcessor()
sp.load(SP_MODEL)

fixtures = []
for text in TESTS:
    ids = sp.encode(text, out_type=int)
    fixtures.append({'text': text, 'expected_ids': ids})

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(fixtures, ensure_ascii=False, indent=2) + '\n')
print(f'Wrote {len(fixtures)} fixtures to {OUT}')
