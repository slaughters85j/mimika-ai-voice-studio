//
//  LavaSRDenoiserModules.swift
//  pocket-tts-macos
//
//  Sub-modules used by ULUNAS (the LavaSR denoiser). Direct ports of
//  the layers defined in `LavaSR/denoiser/ulunas.py`
//  (MIT, Copyright (c) 2026 Xiaobin-Rong).
//
//  Modules in this file:
//
//    LavaSRERB           — ERB filterbank merge / split (frozen Linear)
//    LavaSRAffinePReLU   — per-channel-per-freq affine + PReLU
//    LavaSRShuffle       — channel-shuffle for grouped convolutions
//
//  FA + cTFA modules and the DPGRNN bottleneck use bidirectional GRU,
//  which MLX-Swift's GRU does not provide natively (requires a manual
//  forward + reverse pass). Those land in subsequent Phase 10 commits.
//
//  Phase 10 / Commit 3 — modules introduced as standalone units with
//  per-module parity tests against Python references. Commit 4 wires
//  them into block types; Commit 5 assembles the full encoder/decoder.
//
//  Property naming follows the project's existing pattern for MLX
//  Module subclasses (see `Engine/MimiEncoder.swift`):
//    - Use `nonisolated(unsafe) var name: Type` (no @ParameterInfo /
//      @ModuleInfo) so the class init can stay `nonisolated` to match
//      the base `Module.init()`'s isolation.
//    - Reflection picks up parameters by Swift property name; the
//      load path remaps PyTorch's snake_case keys to our camelCase
//      properties.

import Foundation
import MLX
import MLXNN

// MARK: - LavaSRERB

/// ERB (Equivalent Rectangular Bandwidth) filterbank merge / split.
///
/// Input is a (B, C, T, F) tensor where F = `n_fft / 2 + 1`. The first
/// `erbSubband1` low-frequency bins pass through unchanged; the
/// remaining `(F - erbSubband1)` high bins are projected through the
/// frozen ERB filterbank to `erbSubband2` ERB bands (`bm` — band-merge)
/// or projected back (`bs` — band-split).
final class LavaSRERB: Module {

    /// Default ULUNAS values from `LavaSR/denoiser/ulunas.py` —
    /// `erb_low=65, erb_high=64, n_fft=512`. Exposed as static
    /// constants so the parameterless `init()` can build placeholders
    /// for Swift's strict-concurrency override check, AND so the
    /// parameterized init can default to them.
    nonisolated static let defaultErbSubband1 = 65
    nonisolated static let defaultErbSubband2 = 64
    nonisolated static let defaultNFft = 512

    nonisolated(unsafe) var erbSubband1: Int
    nonisolated(unsafe) var erbSubband2: Int

    /// Linear (no bias). Python key: `erb_fc.weight`. Reflection sees
    /// this property as `erbFc`; the weight-loader remaps `erb_fc → erbFc`
    /// before calling `update(parameters:)`.
    nonisolated(unsafe) var erbFc: Linear

    /// Linear (no bias). Python key: `ierb_fc.weight`. Same remap.
    nonisolated(unsafe) var ierbFc: Linear

    /// Parameterless init required by Swift 6 strict concurrency to
    /// match `Module.init()`'s isolation. Creates layers at the
    /// default ULUNAS shapes; if a different shape is needed use
    /// `init(erbSubband1:erbSubband2:nFft:)` instead.
    nonisolated override init() {
        let nfreqs = Self.defaultNFft / 2 + 1
        self.erbSubband1 = Self.defaultErbSubband1
        self.erbSubband2 = Self.defaultErbSubband2
        self.erbFc = Linear(nfreqs - Self.defaultErbSubband1, Self.defaultErbSubband2, bias: false)
        self.ierbFc = Linear(Self.defaultErbSubband2, nfreqs - Self.defaultErbSubband1, bias: false)
        super.init()
    }

    nonisolated init(erbSubband1: Int, erbSubband2: Int, nFft: Int) {
        precondition(erbSubband1 > 0 && erbSubband2 > 0, "subband counts must be positive")
        let nfreqs = nFft / 2 + 1
        precondition(erbSubband1 < nfreqs, "erbSubband1 must be < nfreqs")
        self.erbSubband1 = erbSubband1
        self.erbSubband2 = erbSubband2
        self.erbFc = Linear(nfreqs - erbSubband1, erbSubband2, bias: false)
        self.ierbFc = Linear(erbSubband2, nfreqs - erbSubband1, bias: false)
        super.init()
    }

    /// Analysis projection: `(B, C, T, F) -> (B, C, T, erbSubband1 + erbSubband2)`.
    /// Matches PyTorch `ERB.bm`.
    func bm(_ x: MLXArray) -> MLXArray {
        let xLow = x[.ellipsis, 0..<erbSubband1]
        let xHigh = erbFc(x[.ellipsis, erbSubband1...])
        return MLX.concatenated([xLow, xHigh], axis: -1)
    }

    /// Synthesis projection: inverse of `bm`. Returns `(B, C, T, F)`.
    /// Matches PyTorch `ERB.bs`.
    func bs(_ xErb: MLXArray) -> MLXArray {
        let xLow = xErb[.ellipsis, 0..<erbSubband1]
        let xHigh = ierbFc(xErb[.ellipsis, erbSubband1...])
        return MLX.concatenated([xLow, xHigh], axis: -1)
    }
}

// MARK: - LavaSRAffinePReLU

/// Per-channel-per-frequency affine transform followed by a PReLU
/// activation. Operates on tensors of shape `(B, C, T, W)` where `C`
/// is the channel count and `W` is the freq-axis width.
///
/// Math (matches `AffinePReLU.forward` in ulunas.py):
///
///   y = affineWeight[None, :, None, :] * x + affineBias[None, :, None, :]
///   y = y + where(x > 0, x, slopeWeight.view(1, -1, 1, 1) * x)
///
/// PyTorch parameter shapes (snake_case → camelCase remap):
///   affine_weight (C, W)  → affineWeight
///   affine_bias   (C, W)  → affineBias
///   slope_weight  (C,)    → slopeWeight
final class LavaSRAffinePReLU: Module {

    nonisolated(unsafe) var affineWeight: MLXArray
    nonisolated(unsafe) var affineBias: MLXArray
    nonisolated(unsafe) var slopeWeight: MLXArray

    /// Parameterless init creates a 1x1 placeholder. Real shapes come
    /// from a follow-up `init(channels:width:)` call or from the
    /// weight-loader overwriting the arrays.
    nonisolated override init() {
        self.affineWeight = MLX.ones([1, 1])
        self.affineBias = MLX.zeros([1, 1])
        self.slopeWeight = MLXArray([Float(0.25)])
        super.init()
    }

    nonisolated init(channels: Int, width: Int, slopeInit: Float = 0.25) {
        precondition(channels > 0 && width > 0, "channels/width must be positive")
        // PyTorch defaults: ones for affine_weight, zeros for affine_bias,
        // constant for slope_weight. Weights get overwritten by load().
        self.affineWeight = MLX.ones([channels, width])
        self.affineBias = MLX.zeros([channels, width])
        self.slopeWeight = MLXArray([Float](repeating: slopeInit, count: channels))
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        precondition(x.ndim == 4, "LavaSRAffinePReLU expects (B, C, T, W); got ndim=\(x.ndim)")
        // affineWeight + affineBias broadcast across B and T:
        //   affineWeight[None, :, None, :]    shape (1, C, 1, W)
        //   x                                  shape (B, C, T, W)
        let aw = affineWeight.expandedDimensions(axis: 0).expandedDimensions(axis: 2)  // (1, C, 1, W)
        let ab = affineBias.expandedDimensions(axis: 0).expandedDimensions(axis: 2)    // (1, C, 1, W)
        let y = aw * x + ab

        // PReLU branch: y + where(x > 0, x, slope * x)
        //   slopeWeight.view(1, -1, 1, 1) → (1, C, 1, 1)
        let sw = slopeWeight
            .expandedDimensions(axis: 0)   // (1, C)
            .expandedDimensions(axis: 2)   // (1, C, 1)
            .expandedDimensions(axis: 3)   // (1, C, 1, 1)
        let prelu = MLX.which(x .> 0, x, sw * x)
        return y + prelu
    }
}

// MARK: - LavaSRShuffle

/// Channel-interleave reorder used between grouped convolutions, so
/// that the two groups' outputs get mixed back together before the
/// next layer. No parameters.
///
/// Input shape: `(B, 2C, T, F)`. Output shape: same.
/// Matches `Shuffle.forward` in ulunas.py exactly.
struct LavaSRShuffle: Sendable {

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        precondition(x.ndim == 4, "LavaSRShuffle expects (B, 2C, T, F); got ndim=\(x.ndim)")
        precondition(x.shape[1] % 2 == 0, "channel dim must be even for shuffle; got \(x.shape[1])")
        let halves = MLX.split(x, parts: 2, axis: 1)            // [(B, C, T, F)] x 2
        let stacked = MLX.stacked([halves[0], halves[1]], axis: 1)  // (B, 2, C, T, F)
        let transposed = stacked.transposed(0, 2, 1, 3, 4)           // (B, C, 2, T, F)
        // Python: rearrange(x, 'b c g t f -> b (c g) t f')
        //   means flatten (C, G=2) into 2C with C-major order, exactly
        //   what reshape does after the transpose.
        let shape = transposed.shape
        // shape = [B, C, 2, T, F]  →  [B, 2*C, T, F]
        return transposed.reshaped(shape[0], shape[1] * shape[2], shape[3], shape[4])
    }
}

// MARK: - LavaSRFA  (TODO — bidirectional GRU port)
//
// PYTHON REFERENCE (LavaSR/denoiser/ulunas.py):
//
//   class FA(nn.Module):
//       def __init__(self, nfreq, freq_comp_ratio=4):
//           super().__init__()
//           self.r = freq_comp_ratio                                  # 4
//           self.gru = nn.GRU(r, r, batch_first=True, bidirectional=True)
//           self.fc = nn.Linear(2*r, r)
//           remainder = nfreq % r
//           self.pad_len = (r - remainder) if remainder else 0
//           self.F_pad = nfreq + self.pad_len
//           self.H = self.F_pad // r
//
//       def forward(self, x):                                          # (B,C,T,F)
//           B, C, T, F = x.shape
//           x = torch.mean(x.pow(2), dim=1)                            # (B,T,F)
//           x = nn.functional.pad(x, (0, self.pad_len))                # (B,T,F_pad)
//           x = x.view(B, T, self.H, self.r)                            # (B,T,H,r)
//           x = rearrange(x, 'b t h c -> (b t) h c')                    # (BT,H,r)
//           x, _ = self.gru(x)                                          # (BT,H,2r)
//           x = self.fc(x)                                              # (BT,H,r)
//           x = rearrange(x, '(b t) h c -> b t h c', b=B)               # (B,T,H,r)
//           x = x.reshape(B, T, self.F_pad)                             # (B,T,F_pad)
//           if self.pad_len > 0: x = x[..., :F]                         # (B,T,F)
//           return x
//
// PORT NOTES:
//
//   * MLX-Swift's GRU is unidirectional. Implement bidir as two GRUs
//     (forward + reverse) whose outputs concat along the hidden dim.
//   * PyTorch weight keys per direction: `weight_ih_l0`, `weight_hh_l0`,
//     `bias_ih_l0`, `bias_hh_l0` plus the `_reverse` variants.
//   * Bias-fusion conversion (PyTorch → MLX-Swift GRU):
//       MLX `Wx`  = PyTorch `weight_ih_l0`
//       MLX `Wh`  = PyTorch `weight_hh_l0`
//       MLX `b[0:2H]`  = `bias_ih_l0[0:2H] + bias_hh_l0[0:2H]`  (sum)
//       MLX `b[2H:3H]` = `bias_ih_l0[2H:3H]`                    (n-gate)
//       MLX `bhn`      = `bias_hh_l0[2H:3H]`                    (n-gate)
//   * No actor-isolation gotcha: still use `nonisolated override init()`
//     placeholder + `nonisolated init(nfreq:freqCompRatio:)` factory.
//   * Per-module parity test target: Pearson ≥ 0.98 vs
//     `*_dpgrnn_0_input.npy` slice (FA is exercised inside the
//     dpgrnn/encoder block — the Python validator does NOT dump FA
//     output in isolation; either bump the validator or test FA only
//     via cTFA which is one level up).

// MARK: - LavaSRcTFA  (TODO — depends on LavaSRFA)
//
// PYTHON REFERENCE:
//
//   class cTFA(nn.Module):                                              # causal time-freq attn
//       def __init__(self, channels, width):
//           super().__init__()
//           self.channels = channels
//           self.ta_gru = nn.GRU(channels, channels*2, 1, batch_first=True)  # unidirectional
//           self.ta_fc  = nn.Linear(channels*2, channels)
//           self.fa     = FA(width)
//
//       def forward(self, x):                                          # (B,C,T,F)
//           zt = torch.mean(x.pow(2), dim=-1)                          # (B,C,T)
//           at = self.ta_gru(zt.transpose(1,2))[0]                     # (B,T,2C)
//           at = self.ta_fc(at).transpose(1,2)                         # (B,C,T)
//           at = torch.sigmoid(at)
//           af = self.fa(x)                                            # (B,T,F)
//           af = torch.sigmoid(af)
//           return at[...,None] * x * af[:, None]                       # broadcast (B,C,T,F)
//
// PORT NOTES:
//
//   * `ta_gru` is UNIDIRECTIONAL — MLX-Swift GRU works directly. Just
//     handle the bias-fusion conversion (same recipe as bidir).
//   * Frequency attention `af` reuses LavaSRFA — port that first.
//   * The broadcast on the output line: `at` is (B,C,T) shaped to
//     (B,C,T,1) via `[...,None]`; `af` is (B,T,F) shaped to (B,1,T,F)
//     via `[:, None]`. Both broadcast against `x` of shape (B,C,T,F).
