//
//  ChatViewModel+Dictation.swift
//  mimika-ai-voice-studio
//
//  Dictation lifecycle extracted from ChatViewModel to stay under
//  the 300-line file budget. Drives the 3-state mic button cycle:
//  idle → listening → ready → submit.

import Foundation

extension ChatViewModel {

    // MARK: - Dictation

    func dictationButtonTapped() {
        switch dictation {
        case .idle:
            Task { await startDictation() }
        case .listening:
            stopDictation()
        case .ready:
            dictation = .idle
            if canSendDraft { send() }
        case .unavailable:
            Task { await startDictation() }
        }
    }

    func startDictation() async {
        if dictationController.authState != .authorized {
            await dictationController.requestAuthorization()
        }
        switch dictationController.authState {
        case .authorized:
            break
        case .denied:
            dictation = .unavailable("Microphone or speech-recognition access denied. Enable in System Settings → Privacy & Security.")
            return
        case .restricted:
            dictation = .unavailable("Speech recognition is restricted on this device.")
            return
        case .notDetermined:
            dictation = .unavailable("Permission prompt was dismissed; click the mic again to retry.")
            return
        case .unavailable(let msg):
            dictation = .unavailable(msg)
            return
        }

        dictationStartingDraft = draft
        dictationCapturedText = ""

        dictationController.onTranscript = { [weak self] partial in
            guard let self else { return }
            self.dictationCapturedText = partial
            let separator = self.dictationStartingDraft.isEmpty || self.dictationStartingDraft.hasSuffix(" ") ? "" : " "
            self.draft = self.dictationStartingDraft + separator + partial
        }
        dictationController.onError = { [weak self] err in
            self?.dictation = .unavailable(String(describing: err))
        }

        do {
            try dictationController.start()
            dictation = .listening
        } catch {
            dictation = .unavailable(String(describing: error))
        }
    }

    func stopDictation() {
        dictationController.stop()
        let captured = dictationCapturedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if captured.isEmpty {
            draft = dictationStartingDraft
            dictation = .idle
        } else {
            dictation = .ready
        }
    }

    var canSendDraft: Bool {
        if case .connected = connectionState {
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }
}
