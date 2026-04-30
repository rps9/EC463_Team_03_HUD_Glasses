import SwiftUI

struct ConversationHistoryView: View {
    @EnvironmentObject private var historyStore: HUDConversationHistoryStore

    @State private var searchText = ""
    @State private var filterListeningCode: String?
    @State private var filterDisplayCode: String?
    @State private var showClearConfirm = false

    private static let sectionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Group {
            if historyStore.entries.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
        .hudScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("History")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !historyStore.entries.isEmpty {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(HUDTheme.rose)
                    }
                    .accessibilityLabel("Clear all history")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search translation or source")
        .confirmationDialog("Clear all saved conversations?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) {
                historyStore.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(HUDTheme.inkMuted)
            Text("No conversations yet")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(HUDTheme.ink)
            Text("Stop listening on Live HUD to save the current translation here.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(HUDTheme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                filterCard

                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(groupedSections, id: \.id) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(HUDTheme.inkMuted)
                                .padding(.horizontal, 4)

                            ForEach(section.entries) { entry in
                                NavigationLink {
                                    ConversationHistoryDetailView(entry: entry)
                                } label: {
                                    historyRow(entry)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        historyStore.remove(id: entry.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }

                if filteredEntries.isEmpty {
                    Text("No matches for your filters or search.")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(HUDTheme.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
    }

    private var filterCard: some View {
        HUDCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Filters")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.inkMuted)

                HStack(spacing: 12) {
                    filterMenu(
                        title: "Heard in",
                        selection: $filterListeningCode,
                        codes: historyStore.distinctListeningCodes
                    )
                    filterMenu(
                        title: "Shown in",
                        selection: $filterDisplayCode,
                        codes: historyStore.distinctDisplayCodes
                    )
                }
            }
        }
    }

    private func filterMenu(title: String, selection: Binding<String?>, codes: [String]) -> some View {
        Menu {
            Button("All languages") {
                selection.wrappedValue = nil
            }
            Divider()
            ForEach(codes, id: \.self) { code in
                Button(TranslationLanguages.displayName(for: code)) {
                    selection.wrappedValue = code
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.inkMuted)
                HStack {
                    Text(selection.wrappedValue.map { TranslationLanguages.displayName(for: $0) } ?? "All")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.ink)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(HUDTheme.inkMuted)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(HUDTheme.strokeStrong, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func historyRow(_ entry: HUDConversationHistoryEntry) -> some View {
        HUDCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(Self.timeFormatter.string(from: entry.createdAt))
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HUDTheme.inkMuted)
                }

                Text(entry.translatedText)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var filteredEntries: [HUDConversationHistoryEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return historyStore.entries.filter { entry in
            if let code = filterListeningCode, entry.listeningLanguageCode != code { return false }
            if let code = filterDisplayCode, entry.displayLanguageCode != code { return false }
            if !q.isEmpty {
                let t = entry.translatedText.lowercased()
                let s = entry.sourceText.lowercased()
                guard t.contains(q) || s.contains(q) else { return false }
            }
            return true
        }
    }

    private var groupedSections: [HistoryDaySection] {
        let entries = filteredEntries
        let cal = Calendar.current
        let grouped = Dictionary(grouping: entries) { entry -> Date in
            cal.startOfDay(for: entry.createdAt)
        }
        let sortedDays = grouped.keys.sorted(by: >)
        return sortedDays.map { day in
            let title = Self.sectionFormatter.string(from: day)
            let dayEntries = (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            return HistoryDaySection(id: title, title: title, entries: dayEntries)
        }
    }
}

private struct HistoryDaySection: Identifiable {
    let id: String
    let title: String
    let entries: [HUDConversationHistoryEntry]
}

struct ConversationHistoryDetailView: View {
    let entry: HUDConversationHistoryEntry

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HUDCard(padding: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Translation")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.inkMuted)
                        Text(entry.translatedText)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(HUDTheme.ink)
                    }
                }

                if !entry.sourceText.isEmpty {
                    HUDCard(padding: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Source (recognized)")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(HUDTheme.inkMuted)
                            Text(entry.sourceText)
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(HUDTheme.ink)
                        }
                    }
                }

                HUDCard(padding: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        metaRow(label: "Time", value: entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        metaRow(
                            label: "Listening language",
                            value: TranslationLanguages.displayName(for: entry.listeningLanguageCode)
                        )
                        metaRow(
                            label: "Display language",
                            value: TranslationLanguages.displayName(for: entry.displayLanguageCode)
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .hudScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Conversation")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)
            }
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(HUDTheme.inkMuted)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(HUDTheme.ink)
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview("History") {
    NavigationStack {
        ConversationHistoryView()
            .environmentObject(HUDConversationHistoryStore())
    }
}
