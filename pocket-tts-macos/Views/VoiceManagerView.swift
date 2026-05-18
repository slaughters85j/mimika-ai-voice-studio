//
//  VoiceManagerView.swift
//  pocket-tts-macos
//
//  Central voice management: view, import, and delete voices for both
//  Pocket-TTS and Fish backends. Import a WAV once → it gets processed
//  for whichever backends are available.

import SwiftUI
import UniformTypeIdentifiers

struct VoiceManagerView: View {
    @Binding var isPresented: Bool
    let pocketTTSVoices: [Voice]
    var onEncodeVoice: ((String) -> Void)?

    @State private var showImporter = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        ModalContainer(title: "Voice Manager", onClose: { isPresented = false }) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                importSection
                Divider().background(Theme.borderColor)
                pocketTTSSection
                Divider().background(Theme.borderColor)
                fishSection
                Divider().background(Theme.borderColor)
                actions
            }
            .frame(maxWidth: 560, maxHeight: 600)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.wav, .mp3, .aiff, .audio],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .task { await verifyAndEncodeVoices() }
    }

    private func verifyAndEncodeVoices() async {
        let needsEncoding = FishVoiceManager.shared.verifyVoiceStates()
        for voiceID in needsEncoding {
            onEncodeVoice?(voiceID)
        }
    }

    // MARK: - Import

    private var importSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("Add a Voice")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: { showImporter = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                        Text("Import WAV")
                            .font(Theme.fontXS)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                .buttonStyle(.plain)
            }
            Text("Import a voice recording (.wav, .mp3, .aiff). The voice will be processed for Fish Speech voice cloning.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)

            if let statusMessage {
                Text(statusMessage)
                    .font(Theme.fontXS)
                    .foregroundStyle(statusIsError ? Theme.errorFG : Theme.successFG)
            }
        }
    }

    // MARK: - Pocket-TTS voices

    private var pocketTTSSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("Pocket TTS Voices")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(pocketTTSVoices.count)")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }

            ScrollView {
                VStack(spacing: Theme.space1) {
                    ForEach(pocketTTSVoices) { voice in
                        voiceRow(
                            name: voice.name,
                            detail: voice.type == .predefined ? "Built-in" : "Custom",
                            badge: voice.type == .predefined ? Theme.badgeSingleBG : Theme.bgTertiary,
                            badgeText: voice.type == .predefined ? Theme.badgeSingleFG : Theme.textSecondary,
                            canDelete: false
                        )
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }

    // MARK: - Fish voices

    private var fishSection: some View {
        let fishVoices = FishVoiceManager.shared.voices

        return VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("Fish Audio Voices")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(fishVoices.count)")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }

            if fishVoices.isEmpty {
                Text("No voices imported yet. Use \"Import WAV\" above to add a voice.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, Theme.space2)
            } else {
                ScrollView {
                    VStack(spacing: Theme.space1) {
                        ForEach(fishVoices) { voice in
                            voiceRow(
                                name: voice.name,
                                detail: voice.cachedCodesPath != nil ? "Encoded" : "Pending",
                                badge: Theme.badgeMultiBG,
                                badgeText: Theme.badgeMultiFG,
                                canDelete: true,
                                onDelete: { FishVoiceManager.shared.deleteVoice(id: voice.id) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack {
            Spacer()
            Button(action: { isPresented = false }) {
                Text("Done")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Voice row

    private func voiceRow(
        name: String,
        detail: String,
        badge: Color,
        badgeText: Color,
        canDelete: Bool,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: Theme.space3) {
            Text(name)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer()

            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(badgeText)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(badge)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))

            if canDelete, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.errorFG)
                }
                .buttonStyle(.plain)
                .help("Delete voice")
            }
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.bgTertiary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    // MARK: - Import handler

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let name = url.deletingPathExtension().lastPathComponent

        guard url.startAccessingSecurityScopedResource() else {
            statusMessage = "Cannot access file"
            statusIsError = true
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let voice = try FishVoiceManager.shared.importVoice(from: url, name: name)
            statusMessage = "Encoding \"\(name)\"..."
            statusIsError = false
            onEncodeVoice?(voice.id)
            statusMessage = "Imported \"\(name)\""
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { statusMessage = nil }
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
            statusIsError = true
        }
    }
}
