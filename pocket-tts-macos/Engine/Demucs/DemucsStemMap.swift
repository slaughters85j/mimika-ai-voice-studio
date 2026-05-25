//
//  DemucsStemMap.swift
//  pocket-tts-macos
//
//  Channel-layout constants for the converted HTDemucs Core ML
//  `mlpackage`. The PyTorch model returns a 4-D tensor of shape
//  `[B, S, C, T]` (batch × stems × channels × time); for Core ML
//  conversion we wrap it in a flatten module that reshapes to
//  `[B, S * C, T]` so the output stays a simple 3-D tensor that
//  `MLMultiArray` can vend without nested dimensions. After the
//  flatten, `S × C = 4 × 2 = 8` channels are packed into dim 1 in
//  fixed source order:
//
//      channels 0,1 → drums  (L, R)
//      channels 2,3 → bass   (L, R)
//      channels 4,5 → other  (L, R)
//      channels 6,7 → vocals (L, R)
//
//  This ordering is baked into the conversion script
//  (`pocket-tts-demucs-coreml-conversion/scripts/02c_convert_surgical_patch.py`,
//  `HTDemucsExport` wrapper). Any change there MUST be mirrored here,
//  or `DemucsSourceSeparator` will silently route the wrong stems
//  into the vocals + music outputs and the entire pipeline will
//  feed background music into the diarizer instead of voices.
//
//  Lifted into its own enum (instead of `private static let` constants
//  inside `DemucsSourceSeparator`) so:
//    * the test target can reference the constants without
//      `@testable` shenanigans, and
//    * a future MLX or MPSGraph-based separator can reuse the same
//      channel ordering without copy-pasting the magic numbers.

import Foundation

// MARK: - DemucsStemMap

/// Constant channel layout for the converted HTDemucs Core ML model.
///
/// The model's `output` MLMultiArray is shaped `[1, 8, T]`. Each
/// numbered pair maps to one (left, right) stereo stem. `mean` of the
/// pair gives the mono downmix for that stem.
///
/// `nonisolated` because the constants are pure value-type data and
/// the default actor isolation (MainActor) would otherwise force a
/// hop just to read an integer literal.
nonisolated enum DemucsStemMap {

    // MARK: - Per-stem channel pairs

    /// Output channel indices for the drum stem: `output[0, 0, :]` is
    /// drums-L, `output[0, 1, :]` is drums-R.
    static let drumsChannels: (left: Int, right: Int) = (0, 1)

    /// Output channel indices for the bass stem.
    static let bassChannels: (left: Int, right: Int) = (2, 3)

    /// Output channel indices for the "other" stem (anything HTDemucs
    /// can't pin to drums / bass / vocals: piano, synth pads, ambient
    /// noise, room tone, SFX, etc.).
    static let otherChannels: (left: Int, right: Int) = (4, 5)

    /// Output channel indices for the vocals stem — the one we feed
    /// into diarization and per-speaker isolation downstream.
    static let vocalsChannels: (left: Int, right: Int) = (6, 7)

    // MARK: - Aggregate constants

    /// Total channels in the flattened output (`S × C = 4 × 2 = 8`).
    /// Doubles as a sanity-check value when reading the `MLMultiArray`
    /// shape at the Core ML boundary — if dim 1 isn't 8, the model
    /// shipped is not the one this constant set was authored for.
    static let totalChannels: Int = 8

    /// Number of distinct stems (drums, bass, other, vocals).
    static let stemCount: Int = 4

    /// Channels per stem (always stereo L/R).
    static let channelsPerStem: Int = 2
}
