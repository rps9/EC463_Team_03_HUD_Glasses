import SwiftUI
import UIKit

struct HUDLiveView: View {
    @EnvironmentObject private var frameManager: FrameBluetoothManager
    @EnvironmentObject private var esp32Manager: ESP32BluetoothManager
    @EnvironmentObject private var conversationHistoryStore: HUDConversationHistoryStore
    @EnvironmentObject private var profileStore: SuggestionProfileStore
    @AppStorage(wrappedValue: true, APIConfig.AppStorageKey.hudSuggestionEnabled) private var suggestionEnabled: Bool
    @AppStorage(wrappedValue: TranslationLanguages.defaultListeningLanguageCode, APIConfig.AppStorageKey.hudListeningLanguageCode) private var storedListeningLanguageCode: String
    @AppStorage("hudini.preferredDevice") private var preferredDeviceRaw: String = HUDDeviceKind.frame.rawValue
    @AppStorage("hudini.bluetoothEnabled") private var bluetoothEnabled: Bool = true
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var suggestionManager = HUDSuggestionManager()
    @State private var targetLanguage: String = "en"
    @State private var listeningLanguageCode: String = TranslationLanguages.defaultListeningLanguageCode
    @State private var listeningLanguageOptions: [TranslationLanguageOption] = TranslationLanguages.supported
    @State private var renderedTextDebounceTask: Task<Void, Never>?
    @State private var lastSentBLEText: String = ""
    @State private var isDeviceSheetPresented: Bool = false
    @State private var pulseAnimating: Bool = false
    @State private var isCustomResponsePresented: Bool = false

    private let hudCharacterLimit: Int = 260
    private static let renderedTextDebounceNanoseconds: UInt64 = 450_000_000
    private static let hudTargetLanguageCode = "en"
    private static var hudTargetLanguageOptions: [TranslationLanguageOption] {
        TranslationLanguages.supported.filter { $0.code == hudTargetLanguageCode }
    }

    private var preferredDevice: HUDDeviceKind {
        HUDDeviceKind(rawValue: preferredDeviceRaw) ?? .frame
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topChipBar
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 12)

                VStack(spacing: 16) {
                    translationHero
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if APIConfig.isSuggestionFeatureEnabled {
                        suggestionCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }

            micFAB
                .padding(.bottom, 28)
        }
        .hudScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Live HUD")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)
            }
        }
        .sheet(isPresented: $isDeviceSheetPresented) {
            DeviceSyncSheet(
                bluetoothEnabled: $bluetoothEnabled,
                preferredDeviceRaw: $preferredDeviceRaw,
                onDismiss: { isDeviceSheetPresented = false }
            )
            .environmentObject(frameManager)
            .environmentObject(esp32Manager)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task {
            await transcriptionManager.requestPermissions()
            await loadListeningLanguages()
            applyInitialLanguageConfiguration()
            frameManager.warmUp()
            esp32Manager.warmUp()
        }
        .onAppear {
            suggestionManager.setProfileSnapshotProvider { [weak profileStore] in
                profileStore?.profile?.compactSnapshot()
            }
        }
        .sheet(isPresented: $isCustomResponsePresented) {
            CustomResponseSheet(
                targetLanguageCode: listeningLanguageCode,
                initialEnglishText: ""
            ) { translatedNative in
                suggestionManager.setCustomResponse(
                    translatedNative: translatedNative,
                    languageCode: listeningLanguageCode
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: listeningLanguageCode, initial: false) { _, newValue in
            transcriptionManager.setListeningLanguage(newValue)
            frameManager.setRecognitionLanguage(newValue)
            esp32Manager.setRecognitionLanguage(newValue)
        }
        .onChange(of: targetLanguage, initial: false) { _, newValue in
            transcriptionManager.setTargetLanguage(newValue)
            frameManager.setTargetLanguage(newValue)
            esp32Manager.setTargetLanguage(newValue)
        }
        .onChange(of: transcriptionManager.renderedText, initial: false) { _, newValue in
            if !shouldUseDeviceMic {
                scheduleDebouncedHUDSideEffects(for: newValue, mirrorToDevice: true)
            }
        }
        .onChange(of: frameManager.renderedText, initial: false) { _, newValue in
            if shouldUseDeviceMic, preferredDevice == .frame {
                scheduleDebouncedHUDSideEffects(for: newValue, mirrorToDevice: false)
            }
        }
        .onChange(of: esp32Manager.renderedText, initial: false) { _, newValue in
            if shouldUseDeviceMic, preferredDevice == .esp32 {
                scheduleDebouncedHUDSideEffects(for: newValue, mirrorToDevice: false)
            }
        }
        .onChange(of: frameManager.state, initial: false) { _, _ in
            if preferredDevice == .frame, !isDeviceConnected {
                lastSentBLEText = ""
            }
        }
        .onChange(of: esp32Manager.state, initial: false) { _, _ in
            if preferredDevice == .esp32, !isDeviceConnected {
                lastSentBLEText = ""
            }
        }
        .onChange(of: preferredDeviceRaw, initial: false) { _, _ in
            lastSentBLEText = ""
            disconnectInactiveDevice()
        }
        .onChange(of: bluetoothEnabled, initial: false) { _, enabled in
            if !enabled {
                if frameManager.isStreaming { frameManager.stopListening() }
                if esp32Manager.isStreaming { esp32Manager.stopListening() }
                frameManager.disconnect()
                esp32Manager.disconnect()
                lastSentBLEText = ""
            }
        }
        .onChange(of: suggestionEnabled, initial: false) { _, enabled in
            guard APIConfig.isSuggestionFeatureEnabled else { return }
            if !enabled {
                renderedTextDebounceTask?.cancel()
                renderedTextDebounceTask = nil
                suggestionManager.clearSuggestion()
            }
        }
        .onChange(of: suggestionManager.suggestionPhonetic, initial: false) { _, newPhonetic in
            guard shouldUseDeviceMic, isDeviceConnected, !isListening else { return }
            let trimmedPhonetic = newPhonetic.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedEnglish = suggestionManager.suggestionEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPhonetic.isEmpty && trimmedEnglish.isEmpty {
                sendClearSuggestionToActiveDevice()
            } else {
                sendSuggestionToActiveDevice(phonetic: trimmedPhonetic, english: trimmedEnglish)
            }
        }
        .onChange(of: isListening, initial: true) { wasListening, listening in
            pulseAnimating = listening
            // Fire suggestion + persist history when listening transitions from
            // true → false, regardless of what triggered the stop (FAB tap,
            // Frame tap, scene background, etc). The Frame-tap path calls
            // frameManager.stopListening() directly and never goes through
            // HUDLiveView.toggleListening(), so centralizing this here keeps
            // all stop paths consistent.
            if wasListening, !listening {
                persistConversationSnapshotIfNonEmpty()
                if APIConfig.isSuggestionFeatureEnabled, suggestionEnabled {
                    let finalText = activeRenderedText
                    if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        suggestionManager.refreshSuggestion(for: finalText, languageCode: listeningLanguageCode)
                    }
                }
            }
        }
        .onDisappear {
            renderedTextDebounceTask?.cancel()
            renderedTextDebounceTask = nil
            if isListening {
                persistConversationSnapshotIfNonEmpty()
            }
            transcriptionManager.stop()
            if frameManager.isStreaming { frameManager.stopListening() }
            if esp32Manager.isStreaming { esp32Manager.stopListening() }
            if APIConfig.isSuggestionFeatureEnabled {
                suggestionManager.clearSuggestion()
            }
        }
    }

    // MARK: - Top chip bar

    private var topChipBar: some View {
        HStack(spacing: 10) {
            languageChip(
                icon: "ear",
                label: listeningLanguageLabel(for: listeningLanguageCode),
                selection: $listeningLanguageCode,
                options: listeningLanguageOptions
            )

            Spacer(minLength: 0)

            deviceStatusChip
        }
    }

    private var deviceStatusChip: some View {
        Button {
            isDeviceSheetPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: deviceStatusIcon)
                    .font(.system(size: 11, weight: .semibold))
                Text(deviceStatusLabel)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(deviceStatusTint)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(deviceStatusTint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().stroke(deviceStatusTint.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: isDeviceConnected)
        .animation(.easeOut(duration: 0.2), value: bluetoothEnabled)
    }

    private var deviceStatusLabel: String {
        if !bluetoothEnabled { return "Phone mic" }
        if isDeviceConnected { return "\(preferredDevice.displayName)" }
        return "Not connected"
    }

    private var deviceStatusIcon: String {
        if !bluetoothEnabled { return "iphone" }
        if isDeviceConnected { return "antenna.radiowaves.left.and.right" }
        return "antenna.radiowaves.left.and.right.slash"
    }

    private var deviceStatusTint: Color {
        if !bluetoothEnabled { return HUDTheme.accent }
        return isDeviceConnected ? HUDTheme.mint : HUDTheme.amber
    }

    // MARK: - Translation hero

    private var translationHero: some View {
        Text(hudDisplayText.isEmpty ? "Translation appears here as you speak." : hudDisplayText)
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .minimumScaleFactor(0.55)
            .lineLimit(hudDisplayText.isEmpty ? 3 : 10)
            .foregroundStyle(hudDisplayText.isEmpty ? HUDTheme.inkMuted : HUDTheme.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(32)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.98), HUDTheme.backgroundTop.opacity(0.9)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 32, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(HUDTheme.strokeStrong.opacity(0.7), lineWidth: 1)
            }
            .shadow(color: HUDTheme.shadow, radius: 22, x: 0, y: 12)
    }

    // MARK: - Suggestion card

    private var suggestionCard: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            isCustomResponsePresented = true
        } label: {
            HUDCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Suggested Reply")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.inkMuted)
                        Spacer()
                        Image(systemName: "pencil.line")
                            .foregroundStyle(HUDTheme.inkMuted)
                    }

                    if suggestionManager.isGenerating {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(suggestionManager.generationStage.isEmpty ? "Working…" : suggestionManager.generationStage)
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(HUDTheme.inkMuted)
                        }
                    } else if suggestionManager.suggestionPhonetic.isEmpty
                              && suggestionManager.suggestionEnglish.isEmpty
                              && suggestionManager.suggestionNative.isEmpty {
                        Text("Stop listening to generate a reply, or tap to write your own.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)
                    } else {
                        if !suggestionManager.suggestionPhonetic.isEmpty {
                            Text(suggestionManager.suggestionPhonetic)
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .foregroundStyle(HUDTheme.ink)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !suggestionManager.suggestionNative.isEmpty {
                            Text(suggestionManager.suggestionNative)
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(HUDTheme.inkMuted)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !suggestionManager.suggestionEnglish.isEmpty {
                            Text(suggestionManager.suggestionEnglish)
                                .font(.system(.callout, design: .rounded))
                                .italic()
                                .foregroundStyle(HUDTheme.inkMuted)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Tap to write your own")
                            .font(.caption2)
                    }
                    .foregroundStyle(HUDTheme.inkMuted.opacity(0.8))
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mic FAB

    private var micFAB: some View {
        let tint = isListening ? HUDTheme.rose : HUDTheme.ink
        return Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            toggleListening()
        } label: {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.4), lineWidth: 2)
                    .frame(width: 84, height: 84)
                    .scaleEffect(pulseAnimating ? 1.15 : 1.0)
                    .opacity(pulseAnimating ? 0 : 0.8)
                    .animation(
                        pulseAnimating
                            ? .easeOut(duration: 1.2).repeatForever(autoreverses: false)
                            : .default,
                        value: pulseAnimating
                    )

                Circle()
                    .fill(tint)
                    .frame(width: 68, height: 68)
                    .shadow(color: tint.opacity(0.35), radius: 16, x: 0, y: 8)

                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isListening ? "Stop Listening" : "Start Listening")
    }

    // MARK: - Language chip helper

    private func languageChip(
        icon: String,
        label: String,
        selection: Binding<String>,
        options: [TranslationLanguageOption]
    ) -> some View {
        Menu {
            Picker("", selection: selection) {
                ForEach(options) { option in
                    Text(option.name).tag(option.code)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(HUDTheme.ink)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.white.opacity(0.82), in: Capsule())
            .overlay {
                Capsule().stroke(HUDTheme.strokeStrong, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
    }

    // MARK: - Text pipeline helpers

    private var hudDisplayText: String {
        let raw = activeRenderedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        if raw.count > hudCharacterLimit {
            return String(raw.suffix(hudCharacterLimit))
        }
        return raw
    }

    private var activeTranscriptText: String {
        if !shouldUseDeviceMic { return transcriptionManager.transcript }
        return preferredDevice == .frame ? frameManager.liveTranscript : esp32Manager.liveTranscript
    }

    private var activeRenderedText: String {
        if !shouldUseDeviceMic { return transcriptionManager.renderedText }
        return preferredDevice == .frame ? frameManager.renderedText : esp32Manager.renderedText
    }

    private var shouldUseDeviceMic: Bool { bluetoothEnabled && isDeviceConnected }

    private var activeDeviceState: FrameBluetoothManager.ConnectionState {
        preferredDevice == .frame ? frameManager.state : esp32Manager.state
    }

    private var isDeviceConnected: Bool {
        if case .connected = activeDeviceState { return true }
        return false
    }

    private var activeManagerIsStreaming: Bool {
        preferredDevice == .frame ? frameManager.isStreaming : esp32Manager.isStreaming
    }

    private var isListening: Bool {
        shouldUseDeviceMic ? activeManagerIsStreaming : transcriptionManager.isTranscribing
    }

    private func toggleListening() {
        if isListening {
            if shouldUseDeviceMic {
                stopActiveDeviceListening()
            } else {
                transcriptionManager.stop()
            }
            renderedTextDebounceTask?.cancel()
            renderedTextDebounceTask = nil
            // Suggestion refresh + history persistence are handled by the
            // .onChange(of: isListening) observer so the Frame-tap stop path
            // (which doesn't come through here) gets the same treatment.
        } else {
            if APIConfig.isSuggestionFeatureEnabled {
                suggestionManager.clearSuggestion()
            }
            if shouldUseDeviceMic {
                sendClearSuggestionToActiveDevice()
                startActiveDeviceListening()
            } else {
                transcriptionManager.startTranscribing(
                    listeningLanguage: listeningLanguageCode,
                    translatingTo: Self.hudTargetLanguageCode
                )
            }
        }
    }

    private func startActiveDeviceListening() {
        switch preferredDevice {
        case .frame:
            frameManager.startTranscribing(
                listeningLanguage: listeningLanguageCode,
                translatingTo: Self.hudTargetLanguageCode
            )
        case .esp32:
            esp32Manager.startTranscribing(
                listeningLanguage: listeningLanguageCode,
                translatingTo: Self.hudTargetLanguageCode
            )
        }
    }

    private func stopActiveDeviceListening() {
        switch preferredDevice {
        case .frame: frameManager.stopListening()
        case .esp32: esp32Manager.stopListening()
        }
    }

    private func sendSuggestionToActiveDevice(phonetic: String, english: String) {
        switch preferredDevice {
        case .frame: frameManager.sendSuggestion(phonetic: phonetic, english: english)
        case .esp32: esp32Manager.sendSuggestion(phonetic: phonetic, english: english)
        }
    }

    private func sendClearSuggestionToActiveDevice() {
        switch preferredDevice {
        case .frame: frameManager.clearSuggestion()
        case .esp32: esp32Manager.clearSuggestion()
        }
    }

    private func disconnectInactiveDevice() {
        switch preferredDevice {
        case .frame:
            if esp32Manager.isStreaming { esp32Manager.stopListening() }
            esp32Manager.disconnect()
        case .esp32:
            if frameManager.isStreaming { frameManager.stopListening() }
            frameManager.disconnect()
        }
    }

    private func scheduleDebouncedHUDSideEffects(for text: String, mirrorToDevice: Bool) {
        renderedTextDebounceTask?.cancel()
        let delay = Self.renderedTextDebounceNanoseconds
        renderedTextDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            if mirrorToDevice {
                pushTranslatedTextToDeviceIfNeeded(text)
            }
        }
    }

    private func pushTranslatedTextToDeviceIfNeeded(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isDeviceConnected else { return }
        guard trimmed != lastSentBLEText else { return }
        lastSentBLEText = trimmed
        switch preferredDevice {
        case .frame: frameManager.sendHUDText(trimmed, isPartial: false)
        case .esp32: esp32Manager.sendHUDText(trimmed, isPartial: false)
        }
    }

    private var targetLanguageLabel: String {
        Self.hudTargetLanguageOptions.first?.name
            ?? TranslationLanguages.displayName(for: Self.hudTargetLanguageCode)
    }

    private func listeningLanguageLabel(for code: String) -> String {
        listeningLanguageOptions.first(where: { $0.code == code })?.name ?? TranslationLanguages.displayName(for: code)
    }

    private func loadListeningLanguages() async {
        let options = await TranslationLanguages.installedTargetOptions()
        listeningLanguageOptions = options
        if !options.contains(where: { $0.code == listeningLanguageCode }) {
            listeningLanguageCode = TranslationLanguages.defaultListeningLanguageCode
        }
        targetLanguage = Self.hudTargetLanguageCode
    }

    private func applyInitialLanguageConfiguration() {
        let resolvedListeningCode: String
        if listeningLanguageOptions.contains(where: { $0.code == storedListeningLanguageCode }) {
            resolvedListeningCode = storedListeningLanguageCode
        } else {
            resolvedListeningCode = listeningLanguageCode
        }

        listeningLanguageCode = resolvedListeningCode
        storedListeningLanguageCode = resolvedListeningCode
        transcriptionManager.setListeningLanguage(resolvedListeningCode)
        frameManager.setRecognitionLanguage(resolvedListeningCode)
        esp32Manager.setRecognitionLanguage(resolvedListeningCode)
        transcriptionManager.setTargetLanguage(targetLanguage)
        frameManager.setTargetLanguage(targetLanguage)
        esp32Manager.setTargetLanguage(targetLanguage)
    }

    private func persistConversationSnapshotIfNonEmpty() {
        let translated = activeRenderedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { return }
        let source = activeTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = HUDConversationHistoryEntry(
            id: UUID(),
            createdAt: Date(),
            sourceText: source,
            translatedText: translated,
            listeningLanguageCode: listeningLanguageCode,
            displayLanguageCode: targetLanguage
        )
        conversationHistoryStore.append(entry)
    }
}

// MARK: - Device Sync Sheet

private struct DeviceSyncSheet: View {
    @Binding var bluetoothEnabled: Bool
    @Binding var preferredDeviceRaw: String
    let onDismiss: () -> Void

    @EnvironmentObject private var frameManager: FrameBluetoothManager
    @EnvironmentObject private var esp32Manager: ESP32BluetoothManager

    private var preferredDevice: HUDDeviceKind {
        HUDDeviceKind(rawValue: preferredDeviceRaw) ?? .frame
    }

    private var activeDeviceState: FrameBluetoothManager.ConnectionState {
        preferredDevice == .frame ? frameManager.state : esp32Manager.state
    }

    private var activeDeviceStatusMessage: String {
        preferredDevice == .frame ? frameManager.statusMessage : esp32Manager.statusMessage
    }

    private var activeDiscoveredDevices: [FrameBluetoothManager.DiscoveredDevice] {
        preferredDevice == .frame ? frameManager.discoveredDevices : esp32Manager.discoveredDevices
    }

    private var isDeviceConnected: Bool {
        if case .connected = activeDeviceState { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Use Bluetooth peripheral", isOn: $bluetoothEnabled)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .tint(HUDTheme.accent)
                        .padding(16)
                        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    if bluetoothEnabled {
                        Picker("Device", selection: $preferredDeviceRaw) {
                            ForEach(HUDDeviceKind.allCases) { kind in
                                Text(kind.displayName).tag(kind.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)

                        deviceStateBody
                    } else {
                        Text("Using the iPhone microphone. Turn on Bluetooth to connect the Frame or ESP32.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)
                    }

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .hudScreen()
            .navigationTitle("Device Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                        .font(.system(.body, design: .rounded, weight: .semibold))
                }
            }
            .onDisappear {
                stopScan()
            }
        }
    }

    @ViewBuilder
    private var deviceStateBody: some View {
        switch activeDeviceState {
        case .idle:
            idleBody
        case .scanning:
            scanningBody
        case .connecting(let name):
            HStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(name)…")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(HUDTheme.inkMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        case .connected(let name):
            connectedBody(name: name)
        }
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(activeDeviceStatusMessage.isEmpty
                 ? "Tap Scan to find your \(preferredDevice.displayName)."
                 : activeDeviceStatusMessage)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(HUDTheme.inkMuted)

            Button {
                beginScan()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Scan")
                }
            }
            .buttonStyle(HUDPrimaryButtonStyle(tint: HUDTheme.accent))
        }
    }

    private var scanningBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                Text("Scanning for \(preferredDevice.displayName)…")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(HUDTheme.inkMuted)
            }

            ForEach(activeDiscoveredDevices) { device in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)
                        Text("RSSI \(device.rssi.intValue) dBm")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)
                    }
                    Spacer()
                    Button("Connect") {
                        connect(device)
                    }
                    .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.accent))
                    .frame(width: 110)
                }
                .padding(12)
                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Button("Stop") {
                stopScan()
            }
            .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.ink))
        }
    }

    private func connectedBody(name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(HUDTheme.mint)
                Text("Connected to \(name)")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)
                Spacer()
                if preferredDevice == .frame, let battery = frameManager.frameBatteryLevel {
                    HStack(spacing: 4) {
                        Image(systemName: batteryIcon(for: battery))
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(battery)%")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                    }
                    .foregroundStyle(batteryTint(for: battery))
                }
            }
            .padding(14)
            .background(HUDTheme.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("Translated output mirrors to the device automatically.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(HUDTheme.inkMuted)

            HStack(spacing: 10) {
                Button {
                    disconnect()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle")
                        Text("Disconnect")
                    }
                }
                .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.rose))

                if preferredDevice == .frame {
                    Button {
                        frameManager.resetFrame()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset")
                        }
                    }
                    .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.amber))
                }
            }
        }
    }

    private func beginScan() {
        switch preferredDevice {
        case .frame: frameManager.beginScanning()
        case .esp32: esp32Manager.beginScanning()
        }
    }

    private func stopScan() {
        switch preferredDevice {
        case .frame: frameManager.stopScanning()
        case .esp32: esp32Manager.stopScanning()
        }
    }

    private func connect(_ device: FrameBluetoothManager.DiscoveredDevice) {
        switch preferredDevice {
        case .frame: frameManager.connect(to: device)
        case .esp32: esp32Manager.connect(to: device)
        }
    }

    private func disconnect() {
        switch preferredDevice {
        case .frame: frameManager.disconnect()
        case .esp32: esp32Manager.disconnect()
        }
    }

    private func batteryIcon(for level: Int) -> String {
        switch level {
        case ..<10: return "battery.0percent"
        case ..<35: return "battery.25percent"
        case ..<60: return "battery.50percent"
        case ..<85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func batteryTint(for level: Int) -> Color {
        if level < 15 { return HUDTheme.rose }
        if level < 30 { return HUDTheme.amber }
        return HUDTheme.mint
    }
}

#Preview {
    NavigationStack {
        HUDLiveView()
            .environmentObject(FrameBluetoothManager())
            .environmentObject(ESP32BluetoothManager())
            .environmentObject(HUDConversationHistoryStore())
    }
}
