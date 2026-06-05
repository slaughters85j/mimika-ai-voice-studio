# Acknowledgments and Third-Party Licenses

Pocket TTS builds on excellent open work from many projects. This
document credits each one and lists their license terms.

## Voice and audio models

### Kyutai Pocket-TTS / Moshi / Mimi codec

- **Source:** https://github.com/kyutai-labs/moshi
- **License:** Creative Commons Attribution 4.0 International
  (CC-BY-4.0) — https://creativecommons.org/licenses/by/4.0/
- **Authors (upstream):** Manu Orsini, Simon Rouard, Gabriel De
  Marmiesse, Vaclav Volhejn, Neil Zeghidour, Alexandre Defossez,
  and contributors at Kyutai Labs.
- **Used in:** The bundled Pocket-TTS voice synthesis engine
  (CaLM autoregressive decoder + Mimi neural codec), the seven
  included stock voices (`alba`, `azelma`, `cosette`, `fantine`,
  `javert`, `jean`, `marius`), and the MimiEncoder used to bake
  imported voices into KV-cache conditioning states.

### Fish Audio S2 Pro

- **Source:** https://huggingface.co/fishaudio
- **License:** Per the Fish Audio model card for the specific
  version distributed. Please consult the upstream model card
  for terms.
- **Used in:** The Fish Audio TTS engine. Weights are downloaded
  on user selection, not bundled with the app.

### NVIDIA NeMo Parakeet TDT v3

- **Source:** https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- **License:** CC-BY-4.0
- **Used in:** Speech-to-text transcription for the Voice Changer,
  Speaker Isolation, and AI Chat dictation features. Downloaded on
  first use via FluidAudio.

### FluidAudio diarizer

- **Source:** https://github.com/FluidInference/FluidAudio
- **License:** Apache 2.0 (Swift package); upstream models are
  pyannote-based. See FluidAudio's documentation for the specific
  model card and terms.
- **Used in:** Speaker diarization for the Speaker Isolation feature.

### Meta Hybrid Transformer Demucs (HTDemucs)

- **Source:** https://github.com/facebookresearch/demucs
- **License:** MIT
- **Used in:** Music-and-ambient separation for the Speaker
  Isolation "Audio Preservation" feature. The Core ML build is
  republished at
  https://huggingface.co/slaughters85j/htdemucs-coreml and
  downloaded only when the user opts into background preservation.

### Vocos (used as the LavaSR base)

- **Source:** https://github.com/gemelo-ai/vocos
- **License:** MIT
- **Used in:** Voice-enhancement bandwidth-extension model
  (the "LavaSR Enhancement" pipeline).

## Swift packages and frameworks

### FluidAudio

- https://github.com/FluidInference/FluidAudio
- License: Apache 2.0

### mlx-swift

- https://github.com/ml-explore/mlx-swift
- License: MIT
- Apple's Swift bindings for the MLX array framework.

### mlx-audio-swift (forked)

- Upstream: https://github.com/Blaizzy/mlx-audio
- Fork used here: https://github.com/slaughters85j/mlx-audio-swift
  (forked to expose Fish S2 Pro codec + reference-codes APIs)
- License: MIT

### swift-transformers

- https://github.com/huggingface/swift-transformers
- License: Apache 2.0

### Apple Swift packages

- swift-collections, swift-atomics, swift-nio, swift-crypto,
  swift-numerics, swift-system, swift-asn1, swift-syntax,
  swift-huggingface, swift-jinja, mlx-swift-lm
- License: Apache 2.0 (each)

### yyjson

- https://github.com/ibireme/yyjson
- License: MIT

### EventSource

- https://github.com/mattt/EventSource
- License: MIT

## Apple frameworks

Pocket TTS uses Core ML, MLX, AVFoundation, SwiftUI, SwiftData,
Accelerate, Metal, Foundation, AppKit, and other frameworks
provided by Apple as part of macOS. These frameworks are
governed by Apple's standard SDK terms.

## License texts

The license terms for each project above govern that project's use.
This section reproduces the texts of the most common licenses for
convenience.

### MIT License

Applies to projects above marked "MIT" (HTDemucs, Vocos, mlx-swift,
mlx-audio-swift, yyjson, EventSource). Each project carries its own
copyright notice; consult each upstream repository for the canonical
text.

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

### Apache License 2.0

Applies to projects above marked "Apache 2.0" (FluidAudio,
swift-transformers, the Apple Swift packages, etc.).

Full text: https://www.apache.org/licenses/LICENSE-2.0

Key conditions, paraphrased — see the full text for legally binding
terms:

1. You may freely use, modify, and distribute the software.
2. You must retain the original copyright notice and a copy of the
   Apache 2.0 license with any redistribution.
3. You must indicate any significant changes you made.
4. The software is provided "as is" without warranty.
5. Contributors grant a patent license; certain patent retaliation
   provisions apply.

### Creative Commons Attribution 4.0 International (CC-BY-4.0)

Applies to projects above marked "CC-BY-4.0" (Kyutai Pocket-TTS /
Moshi / Mimi codec and the seven included Kyutai stock voices;
NVIDIA Parakeet TDT v3).

Full text: https://creativecommons.org/licenses/by/4.0/legalcode

You are free to:

- **Share** — copy and redistribute the material in any medium or
  format
- **Adapt** — remix, transform, and build upon the material for any
  purpose, even commercially

Under the following terms:

- **Attribution** — You must give appropriate credit, provide a link
  to the license, and indicate if changes were made. This file is
  Pocket TTS's attribution to the original creators.
- **No additional restrictions** — You may not apply legal terms or
  technological measures that legally restrict others from doing
  anything the license permits.

## Pocket TTS native code

The Swift code in this repository (the application itself, including
the MimiEncoder port, LavaSR pipeline, voice management, Speaker
Isolation pipeline, WSOLA time-compressor, and Metal orb shader) was
written by John Saunders.

For questions about this acknowledgments document, please open an
issue at:

https://github.com/slaughters85j/mimika-ai-voice-studio/issues
