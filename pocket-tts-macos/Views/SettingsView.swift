//
//  SettingsView.swift
//  pocket-tts-macos
//

import SwiftUI

struct SettingsView: View {
    @Binding var isPresented: Bool
    @Binding var settings: ChatSettings
    let voices: [Voice]
    let onSave: (ChatSettings) -> Void

    @State private var workingCopy: ChatSettings
    @State private var availableModels: [String] = []
    @State private var modelLoadError: String? = nil
    @State private var probeState: ProbeState = .idle

    init(
        isPresented: Binding<Bool>,
        settings: Binding<ChatSettings>,
        voices: [Voice],
        onSave: @escaping (ChatSettings) -> Void
    ) {
        self._isPresented = isPresented
        self._settings = settings
        self.voices = voices
        self.onSave = onSave
        self._workingCopy = State(initialValue: settings.wrappedValue)
    }

    enum ProbeState: Equatable {
        case idle
        case probing
        case ok(String)
        case fail(String)
    }

    var body: some View {
        ModalContainer(title: "Settings", onClose: cancel) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                lmStudioSection
                Divider().background(Theme.borderColor)
                voiceSection
                Divider().background(Theme.borderColor)
                systemPromptSection
                Divider().background(Theme.borderColor)
                actions
            }
            .frame(maxWidth: 560)
        }
        .task { await loadModels() }
    }

    // MARK: - Sections

    private var lmStudioSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("LM Studio").font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)

            HStack {
                Text("Base URL").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
                TextField("http://localhost:1234", text: $workingCopy.baseURL)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, Theme.space2)
                    .themeInputField()
                    .accessibilityIdentifier("settings.baseURL")
            }

            HStack {
                Text("Model").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
                Picker("", selection: $workingCopy.model) {
                    Text("(none yet)").tag("")
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("settings.modelPicker")
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { Task { await loadModels() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Refresh model list")
                .accessibilityIdentifier("settings.refreshModels")
            }

            if let modelLoadError {
                Text(modelLoadError)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.errorFG)
            }

            HStack(spacing: Theme.space2) {
                Button(action: { Task { await testConnection() } }) {
                    Text("Test Connection")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(probeState == .probing)

                switch probeState {
                case .idle: EmptyView()
                case .probing:
                    ProgressView().controlSize(.mini)
                case let .ok(model):
                    Text("✓ \(model)")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.successFG)
                case let .fail(reason):
                    Text("✗ \(reason)")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.errorFG)
                }
            }
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("TTS Voice for chat replies")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

            Picker("", selection: $workingCopy.ttsVoiceID) {
                Section("Built-in") {
                    ForEach(voices.filter { $0.type == .predefined }, id: \.id) { v in
                        Text(v.name).tag(v.id)
                    }
                }
                Section("Custom") {
                    ForEach(voices.filter { $0.type == .custom }, id: \.id) { v in
                        Text(v.name).tag(v.id)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeInputField()
        }
    }

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("System Prompt (optional)")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
            Text("Sent as the first system message in every conversation.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
            TextEditor(text: $workingCopy.systemPrompt)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(Theme.space3)
                .frame(minHeight: 80, maxHeight: 160)
                .themeInputField()
                .accessibilityIdentifier("settings.systemPrompt")
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button(action: cancel) {
                Text("Cancel")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
            }
            .buttonStyle(.plain)

            Button(action: saveAndClose) {
                Text("Done")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.doneButton")
        }
    }

    // MARK: - Actions

    private func cancel() {
        isPresented = false
    }

    private func saveAndClose() {
        settings = workingCopy
        onSave(workingCopy)
        isPresented = false
    }

    private func loadModels() async {
        modelLoadError = nil
        guard let url = URL(string: workingCopy.baseURL) else {
            modelLoadError = "Invalid URL"
            return
        }
        let client = LMStudioClient(baseURL: url)
        do {
            let list = try await client.listModels()
            availableModels = list
            if workingCopy.model.isEmpty, let first = list.first {
                workingCopy.model = first
            }
        } catch {
            modelLoadError = "Couldn't reach \(workingCopy.baseURL)"
        }
    }

    private func testConnection() async {
        probeState = .probing
        guard let url = URL(string: workingCopy.baseURL) else {
            probeState = .fail("invalid URL")
            return
        }
        let client = LMStudioClient(baseURL: url)
        do {
            let list = try await client.listModels()
            if let first = list.first {
                probeState = .ok(first)
            } else {
                probeState = .fail("no models")
            }
        } catch {
            probeState = .fail("unreachable")
        }
    }
}
