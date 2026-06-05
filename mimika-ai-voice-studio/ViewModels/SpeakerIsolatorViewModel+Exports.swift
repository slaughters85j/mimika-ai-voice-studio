//
//  SpeakerIsolatorViewModel+Exports.swift
//  mimika-ai-voice-studio
//
//  Export-related methods for the Speaker Isolator view model.
//  Extracted from the main VM file so the orchestration logic
//  there can stay focused on the pipeline phases.
//
//  Functions here:
//    * `exportSingleSpeaker(at:)` — per-row Save panel + WAV write
//    * `exportAllIsolated()` — folder picker + batch WAV write
//    * `writeTrack(_:to:)` — honors `preserveSilenceForIsolatedExport`
//    * `stripSilence(_:)` — pragmatic concat: collapse zero ranges
//    * `saveCombinedAudio(_:)` — re-voice WAV save panel
//    * `configureExportPanel(_:inputURL:suffix:ext:fallbackFilename:)`
//      — defaults the panel into the input file's directory
//    * `suggestedExportFilename(for:suffix:ext:)` — basename builder
//    * `refuseOverwriteError(outURL:inputURL:)` — last-line-of-defense
//      check that we're not about to clobber the source file
//
//  The Save panel helpers (`configureExportPanel`,
//  `suggestedExportFilename`, `refuseOverwriteError`) are `static`
//  so they're unit-testable without instantiating the @MainActor VM.

import AppKit
import Foundation
import UniformTypeIdentifiers

extension SpeakerIsolatorViewModel {

    // MARK: - Export isolated (per-row or batch)

    /// Per-row Save panel for a single speaker. Caller supplies the
    /// speaker's row index (since the UI passes it from the row's
    /// action closure). Honors `preserveSilenceForIsolatedExport`.
    func exportSingleSpeaker(at index: Int) {
        guard index >= 0, index < speakers.count else { return }
        let track = speakers[index]
        let panel = NSSavePanel()
        panel.title = "Export Isolated Speaker"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(track.displayName).wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeTrack(track, to: url)
    }

    /// Batch export to a chosen folder. Each speaker writes
    /// `<displayName>.wav`.
    func exportAllIsolated() {
        let panel = NSOpenPanel()
        panel.title = "Choose folder to export isolated speakers"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        for track in speakers {
            let url = folder.appendingPathComponent("\(track.displayName).wav")
            writeTrack(track, to: url)
        }
    }

    /// Honors `preserveSilenceForIsolatedExport`. When false, writes
    /// a concatenated WAV (no silence) by re-running SpeakerIsolator
    /// with the speaker's pre-recorded segments — we cache the
    /// silence-padded buffer; concat mode needs the segment list,
    /// which we don't retain across the convert step. So for the
    /// concat case, we re-derive concat by collapsing the silence-
    /// padded buffer: scanning for non-zero ranges. Pragmatic and
    /// avoids re-running diarization.
    func writeTrack(_ track: SpeakerTrack, to url: URL) {
        do {
            let samples: [Float]
            if preserveSilenceForIsolatedExport {
                samples = track.isolatedSamples
            } else {
                samples = Self.stripSilence(track.isolatedSamples)
            }
            try WAVEncoder.write(samples: samples, to: url, sampleRate: 24_000)
        } catch {
            FileHandle.standardError.write(Data("[SpeakerIsolator] export failed for \(track.displayName): \(error)\n".utf8))
        }
    }

    /// Collapse a silence-padded buffer to its non-zero ranges only,
    /// concatenated back-to-back. Mirrors the
    /// `SpeakerIsolator.isolate(preserveSilence: false)` output
    /// without re-running diarization. Acceptable because the
    /// silence regions in an isolated track are EXACT zeros (we
    /// copied input samples at speaker times into a zero-filled
    /// buffer).
    static func stripSilence(_ samples: [Float]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(samples.count / 4)  // rough guess
        for s in samples where s != 0 {
            out.append(s)
        }
        return out
    }

    // MARK: - Combined-audio save flow

    /// Writes the multi-speaker revoice output as a WAV. Builds the
    /// Save panel with `configureExportPanel`, refuses to overwrite
    /// the input file, and either advances state to `.done` or
    /// `.error` based on the write result.
    ///
    /// Format follows the bed-based mix: AP-on path yields a stereo
    /// 44.1 kHz AudioBuffer; AP-off path yields mono 24 kHz. The
    /// AudioBuffer-aware `WAVEncoder.write` dispatcher picks the
    /// right encoder shape so the WAV's channel + rate fields match
    /// the perceived output.
    func saveCombinedAudio(_ combined: AudioBuffer) {
        let panel = NSSavePanel()
        panel.title = "Export re-voiced audio"
        panel.allowedContentTypes = [.wav]
        Self.configureExportPanel(
            panel,
            inputURL: self.inputAudioURL,
            suffix: "re-voiced",
            ext: "wav",
            fallbackFilename: "re-voiced-output.wav"
        )
        guard panel.runModal() == .OK, let outURL = panel.url else {
            statusDoneIfActive()
            return
        }
        if let err = Self.refuseOverwriteError(outURL: outURL, inputURL: self.inputAudioURL) {
            statusError(err)
            return
        }
        do {
            try WAVEncoder.write(audioBuffer: combined, to: outURL)
            statusDoneIfActive()
        } catch {
            statusError("Failed to write \(outURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Save-panel helpers

    /// Configure an `NSSavePanel` to default into the input file's
    /// directory with a `<basename>_<suffix>.<ext>` filename. Prevents
    /// the "I accidentally overwrote my input" failure mode where
    /// the panel's blank default landed wherever the user last
    /// saved a file (and they navigated to the input's folder + kept
    /// hitting Save without noticing the filename collision).
    ///
    /// `static` so it can be unit-tested without an instance.
    static func configureExportPanel(
        _ panel: NSSavePanel,
        inputURL: URL?,
        suffix: String,
        ext: String,
        fallbackFilename: String
    ) {
        guard let inputURL else {
            panel.nameFieldStringValue = fallbackFilename
            return
        }
        panel.directoryURL = inputURL.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedExportFilename(
            for: inputURL, suffix: suffix, ext: ext
        )
    }

    /// `interview.mp4` + `re-voiced` + `mp4` → `interview_re-voiced.mp4`.
    static func suggestedExportFilename(
        for inputURL: URL,
        suffix: String,
        ext: String
    ) -> String {
        let base = inputURL.deletingPathExtension().lastPathComponent
        return "\(base)_\(suffix).\(ext)"
    }

    /// Returns a human-readable error string if `outURL` resolves to
    /// the same path as `inputURL` (including across symlinks), nil
    /// otherwise. Used as the last line of defense against
    /// accidentally clobbering the source file when the user
    /// navigates the save panel to the input's filename.
    static func refuseOverwriteError(
        outURL: URL,
        inputURL: URL?
    ) -> String? {
        guard let inputURL else { return nil }
        let outPath = outURL.resolvingSymlinksInPath().standardizedFileURL.path
        let inPath = inputURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard outPath == inPath else { return nil }
        return "Refusing to overwrite the input file at \(inPath). Pick a different filename or location and try again."
    }
}
