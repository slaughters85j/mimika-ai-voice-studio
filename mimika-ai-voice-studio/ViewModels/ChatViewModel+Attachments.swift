//
//  ChatViewModel+Attachments.swift
//  mimika-ai-voice-studio
//
//  Shared picker/drop import, multimodal send lifecycle, and Vision recovery.

import Foundation

extension ChatViewModel {
    // MARK: Attachment import

    /// Import file URLs from either NSOpenPanel or SwiftUI drop handling.
    func importImageURLs(_ urls: [URL]) async {
        guard supportsVision else {
            showToast("The current model does not support Vision.")
            return
        }
        guard !isComposerLocked else {
            showToast("Please wait until the model accepts the current request.")
            return
        }

        let payloads = await Task.detached(priority: .userInitiated) {
            urls.map { url -> (filename: String, data: Data?, error: String?) in
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    return (
                        url.lastPathComponent,
                        try Data(contentsOf: url, options: .mappedIfSafe),
                        nil
                    )
                } catch {
                    return (url.lastPathComponent, nil, "\(url.lastPathComponent) could not be read.")
                }
            }
        }.value

        await importImagePayloads(payloads)
    }

    /// Validate raw picker/drop payloads and append every valid batch member.
    func importImagePayloads(_ payloads: [(filename: String, data: Data?, error: String?)]) async {
        var fingerprints = Set(
            messages.flatMap(\.attachments).map(\.fingerprint)
                + pendingAttachments.map(\.fingerprint)
        )
        var encodedBytes = totalEncodedImageBytes
        var rejectionMessages: [String] = []

        for payload in payloads {
            if let error = payload.error {
                rejectionMessages.append(error)
                continue
            }
            guard let data = payload.data else {
                rejectionMessages.append("\(payload.filename) could not be read.")
                continue
            }
            guard pendingAttachments.count < ChatImageLimits.maxImagesPerTurn else {
                rejectionMessages.append("A turn can include at most 10 images.")
                break
            }

            let existingFingerprints = fingerprints
            let result = await Task.detached(priority: .userInitiated) {
                ChatImageValidator.validate(
                    data: data,
                    filename: payload.filename,
                    existingFingerprints: existingFingerprints
                )
            }.value

            switch result {
            case let .rejected(message):
                rejectionMessages.append(message)
            case let .accepted(attachment):
                guard encodedBytes + attachment.encodedURLByteCount
                        <= ChatImageLimits.maxEncodedRequestBytes
                else {
                    rejectionMessages.append(
                        "\(attachment.filename) would exceed the 64 MiB encoded request limit."
                    )
                    continue
                }
                pendingAttachments.append(attachment)
                fingerprints.insert(attachment.fingerprint)
                encodedBytes += attachment.encodedURLByteCount
            }
        }

        if !rejectionMessages.isEmpty {
            showToast(rejectionMessages.joined(separator: " "))
        }
    }

    /// Accept a drop only when its transfer can enter the shared import pipeline.
    func shouldHandleImageDrop(_ urls: [URL]) -> Bool {
        guard supportsVision else {
            showToast("The current model does not support Vision.")
            return false
        }
        guard !isComposerLocked else {
            showToast("Please wait until the model accepts the current request.")
            return false
        }
        guard !urls.isEmpty else { return false }

        let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        guard urls.contains(where: {
            supportedExtensions.contains($0.pathExtension.lowercased())
        }) else {
            showToast("Only PNG, JPEG/JPG, and WebP images can be added.")
            return false
        }
        return true
    }

    /// Remove one unsent composer attachment.
    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        if previewAttachment?.id == id { previewAttachment = nil }
    }

    /// Image data already retained by transcript history and the composer.
    var totalEncodedImageBytes: Int {
        messages
            .flatMap(\.attachments)
            .reduce(0) { $0 + $1.encodedURLByteCount }
            + pendingAttachments.reduce(0) { $0 + $1.encodedURLByteCount }
    }

    // MARK: Send lifecycle

    /// Submit the composer or explain why the current turn cannot send yet.
    func send() {
        if activeTurn != nil {
            showToast("Please wait until the model finishes responding.")
            return
        }
        guard case let .connected(model) = connectionState else { return }

        let userText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty || !pendingAttachments.isEmpty else { return }
        // A local server generates one response at a time. Never let the decorative sidebar-title request sit in front of the user's turn.
        cancelSoloThemeRequest()
        if let imageHistorySendBlockMessage {
            if capabilityState.freshness == .current {
                requestVisionRecoveryWhenSafe()
            }
            showToast(imageHistorySendBlockMessage)
            return
        }
        if !pendingAttachments.isEmpty, !supportsVision {
            showToast(
                "The current model does not support Vision. Remove the images, choose a Vision model, or enable an override."
            )
            return
        }
        guard totalEncodedImageBytes <= ChatImageLimits.maxEncodedRequestBytes else {
            showToast("Image history exceeds the 64 MiB encoded request limit.")
            return
        }

        if dictation == .listening { dictationController.stop() }
        dictation = .idle

        let originalDraft = draft
        let originalAttachments = pendingAttachments
        draft = ""
        pendingAttachments = []

        let userMessageID = UUID()
        let assistantMessageID = UUID()
        messages.append(
            ChatMessage(
                id: userMessageID,
                role: .user,
                content: userText,
                attachments: originalAttachments,
                deliveryState: originalAttachments.isEmpty ? nil : .pending
            )
        )
        messages.append(ChatMessage(id: assistantMessageID, role: .assistant))
        noteSoloThreadActivity()

        let turn = ActiveChatTurn(
            userMessageID: userMessageID,
            assistantMessageID: assistantMessageID,
            originalDraft: originalDraft,
            originalAttachments: originalAttachments
        )
        activeTurn = turn
        status = .generating

        let promptConfiguration = currentChatPromptConfiguration()
        let requestMessages = messagesForRequest()
        let reasoningEffort = reasoningEffortForRequest
        let (sentenceStream, sentenceContinuation) = AsyncStream<String>.makeStream()

        turn.llmTask = Task { [weak self] in
            guard let self else { return }
            await self.runLLM(
                turn: turn,
                messages: requestMessages,
                model: model,
                systemPrompt: promptConfiguration.systemPrompt,
                inference: promptConfiguration.inference,
                reasoningEffort: reasoningEffort,
                sentenceContinuation: sentenceContinuation
            )
        }
        turn.ttsTask = Task { [weak self] in
            guard let self else { return }
            await self.runTTS(turn: turn, sentences: sentenceStream)
        }
    }

    /// Cancel the active turn while preserving acceptance-specific semantics.
    func cancel() {
        guard let turn = activeTurn else { return }
        turn.cancel()
        if turn.phase == .awaitingAcceptance {
            rollbackUnacceptedTurn(turn, error: nil)
        } else {
            status = .idle
        }
        Task { await player.stop() }
    }

    /// Consume HTTP acceptance and SSE deltas for one captured turn.
    private func runLLM(
        turn: ActiveChatTurn,
        messages: [ChatMessage],
        model: String,
        systemPrompt: String,
        inference: ChatInferenceSettings,
        reasoningEffort: String?,
        sentenceContinuation: AsyncStream<String>.Continuation
    ) async {
        defer {
            sentenceContinuation.finish()
            turn.llmFinished = true
            finishTurnIfSettled(turn)
        }

        let detector = SentenceDetector()
        let stream = makeClient().streamChatEvents(
            messages: messages,
            model: model,
            systemPrompt: systemPrompt,
            temperature: inference.temperature,
            maxTokens: inference.maxTokens,
            topP: inference.topP,
            topK: inference.topK,
            repeatPenalty: inference.repeatPenalty,
            reasoningEffort: reasoningEffort
        )
        do {
            for try await event in stream {
                guard activeTurn?.id == turn.id else { return }
                switch event {
                case .accepted:
                    acceptTurn(turn)
                case let .delta(text):
                    appendToAssistant(id: turn.assistantMessageID, delta: text)
                    for sentence in detector.append(text) {
                        sentenceContinuation.yield(sentence)
                    }
                }
            }
            if let tail = detector.flush() {
                sentenceContinuation.yield(tail)
            }
        } catch {
            guard activeTurn?.id == turn.id else { return }
            if turn.phase == .awaitingAcceptance {
                rollbackUnacceptedTurn(turn, error: turn.wasCancelled ? nil : error)
            } else if !turn.wasCancelled {
                status = .error(shortError(error))
            }
        }
    }

    /// Consume detected sentences serially through TTS and playback.
    private func runTTS(turn: ActiveChatTurn, sentences: AsyncStream<String>) async {
        defer {
            turn.ttsFinished = true
            finishTurnIfSettled(turn)
        }

        var sentenceIndex = 0
        for await sentence in sentences {
            if Task.isCancelled { break }
            guard activeTurn?.id == turn.id else { return }
            sentenceIndex += 1
            status = .speaking(sentenceIndex: sentenceIndex)

            let voiceID = settings.ttsVoiceID
            let speakable = TextNormalizer.stripEmojis(
                TextNormalizer.stripStageDirections(
                    sentence,
                    stripBracketedTags: settings.activeBackend == .pocketTTS
                )
            )
            guard !speakable.isEmpty else { continue }
            let stream = VoiceLevel.applyingGain(
                to: engine.synthesize(
                    text: speakable,
                    voiceID: voiceID,
                    options: currentSynthesisOptions(for: voiceID)
                ),
                forVoice: voiceID
            )
            do {
                try await player.play(stream: stream)
            } catch {
                if !turn.wasCancelled {
                    status = .error("Speech playback failed: \(shortError(error))")
                }
                break
            }
        }
    }

    /// Mark the provisional user images accepted only after a real HTTP 2xx.
    private func acceptTurn(_ turn: ActiveChatTurn) {
        guard turn.phase == .awaitingAcceptance else { return }
        turn.phase = .accepted
        if let index = messages.firstIndex(where: { $0.id == turn.userMessageID }),
           !messages[index].attachments.isEmpty {
            messages[index].deliveryState = .accepted
        }
    }

    /// Remove a rejected provisional turn and restore the exact composer snapshot.
    private func rollbackUnacceptedTurn(_ turn: ActiveChatTurn, error: Error?) {
        guard turn.phase == .awaitingAcceptance else { return }
        turn.phase = .terminal
        messages.removeAll { $0.id == turn.userMessageID || $0.id == turn.assistantMessageID }
        draft = turn.originalDraft
        pendingAttachments = turn.originalAttachments
        status = error.map { .error(shortError($0)) } ?? .idle
    }

    /// Release the single-flight gate after both LLM and TTS have stopped.
    private func finishTurnIfSettled(_ turn: ActiveChatTurn) {
        guard turn.isSettled, activeTurn?.id == turn.id else { return }
        turn.phase = .terminal
        activeTurn = nil
        if case .generating = status { status = .idle }
        if case .speaking = status { status = .idle }
        noteSoloThreadActivity()

        if deferredVisionRecovery {
            deferredVisionRecovery = false
            if !supportsVision, hasImageHistory {
                showsVisionRecovery = true
            }
        }
    }

    /// Append one SSE delta only to the matching assistant placeholder.
    private func appendToAssistant(id: UUID, delta: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += delta
    }

    /// Exclude the trailing UI-only assistant placeholder from the request.
    private func messagesForRequest() -> [ChatMessage] {
        var result = messages
        if result.last?.role == .assistant,
           result.last?.content.isEmpty == true,
           result.last?.attachments.isEmpty == true {
            result.removeLast()
        }
        return result
    }

}
