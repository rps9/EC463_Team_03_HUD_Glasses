import SwiftUI

// MARK: - Shared form (setup + edit all)

struct SuggestionProfileFormView: View {
    @Binding var profile: SuggestionUserProfile
    @ObservedObject var locationHelper: SuggestionLocationHelper

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            formSection(title: "About you") {
                fieldLabel("Name")
                hudMultilineField(text: $profile.name, placeholder: "Your name")
                fieldLabel("Native language")
                hudMultilineField(text: $profile.nativeLanguage, placeholder: "e.g. English")
                NavigationLink {
                    SuggestionOtherLanguagesEditor(languages: $profile.otherLanguages)
                        .navigationTitle("Other languages")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        fieldLabelInline("Other languages & level")
                        Spacer()
                        Text("\(profile.otherLanguages.count)")
                            .foregroundStyle(HUDTheme.inkMuted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HUDTheme.inkMuted)
                    }
                    .padding(14)
                    .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(HUDTheme.strokeStrong, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)

                fieldLabel("Home country / city")
                hudMultilineField(text: $profile.homeCountryCity, placeholder: "City, country")
                fieldLabel("Occupation / role (optional)")
                hudMultilineField(text: $profile.occupation, placeholder: "Job or role")
            }

            formSection(title: "Health, diet & culture") {
                fieldLabel("Dietary restrictions / allergies — important")
                hudMultilineField(text: $profile.dietaryRestrictions, placeholder: "Allergies, restrictions…")
                fieldLabel("Health considerations (optional)")
                hudMultilineField(text: $profile.healthConsiderations, placeholder: "Hearing, mobility, etc.")
                fieldLabel("Religion / cultural considerations (optional)")
                hudMultilineField(text: $profile.religionCultural, placeholder: "")
                fieldLabel("Food preferences")
                hudMultilineField(text: $profile.foodPreferences, placeholder: "Likes / dislikes")
            }

            formSection(title: "Conversation style") {
                fieldLabel("Hobbies & interests")
                hudMultilineField(text: $profile.hobbiesInterests, placeholder: "")
                fieldLabel("Favorite topics (sports, travel, tech…)")
                hudMultilineField(text: $profile.favoriteTopics, placeholder: "")
                fieldLabel("Things you avoid discussing")
                hudMultilineField(text: $profile.topicsToAvoid, placeholder: "")

                fieldLabel("Tone preference")
                Picker("", selection: $profile.tonePreference) {
                    ForEach(SuggestionTonePreference.allCases) { tone in
                        Text(tone.displayName).tag(tone)
                    }
                }
                .pickerStyle(.segmented)
                .tint(HUDTheme.accent)

                fieldLabel("Personality style (short answers, chatty, humorous, direct…)")
                hudMultilineField(text: $profile.personalityStyle, placeholder: "")
                fieldLabel("Typical use cases (travel, business, dating, daily life…)")
                hudMultilineField(text: $profile.typicalUseCases, placeholder: "")
                fieldLabel("Never suggest anything involving")
                hudMultilineField(text: $profile.neverSuggestInvolving, placeholder: "Topics or situations to block")
            }

            formSection(title: "Current location") {
                Text("HUDini only requests your location when you tap detect — not continuous tracking.")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(HUDTheme.inkMuted)

                Toggle("Allow location for suggestion context", isOn: $profile.agreedToLocationForSuggestions)
                    .tint(HUDTheme.accent)

                Button {
                    if profile.agreedToLocationForSuggestions {
                        locationHelper.requestWhenInUseAccess()
                    }
                    locationHelper.detectCurrentLocation()
                } label: {
                    HStack {
                        if locationHelper.isLocating {
                            ProgressView()
                        }
                        Text("Detect current location")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(HUDSecondaryButtonStyle())
                .disabled(!profile.agreedToLocationForSuggestions)

                if let err = locationHelper.lastErrorMessage {
                    Text(err)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(HUDTheme.rose)
                }

                fieldLabel("Location (auto-filled or type yourself)")
                hudMultilineField(text: $profile.currentLocationDisplay, placeholder: "City, neighborhood…")
            }
        }
        .onChange(of: locationHelper.lastResolvedDisplay, initial: false) { _, new in
            guard profile.agreedToLocationForSuggestions, let new, !new.isEmpty else { return }
            profile.currentLocationDisplay = new
            profile.lastKnownLatitude = locationHelper.lastResolvedLatitude
            profile.lastKnownLongitude = locationHelper.lastResolvedLongitude
        }
    }

    private func formSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        HUDCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)
                content()
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(HUDTheme.inkMuted)
    }

    private func fieldLabelInline(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(HUDTheme.inkMuted)
    }

    private func hudMultilineField(text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .font(.system(.body, design: .rounded))
            .lineLimit(3...10)
            .padding(14)
            .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(HUDTheme.strokeStrong, lineWidth: 1)
            }
            .foregroundStyle(HUDTheme.ink)
    }
}

// MARK: - Other languages editor

struct SuggestionOtherLanguagesEditor: View {
    @Binding var languages: [SuggestionOtherLanguage]

    var body: some View {
        List {
            Section {
                ForEach($languages) { $entry in
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Language", text: $entry.language)
                        TextField("Level (e.g. fluent, conversational)", text: $entry.level)
                    }
                    .listRowBackground(Color.white.opacity(0.55))
                }
                .onDelete { languages.remove(atOffsets: $0) }
            }

            Section {
                Button {
                    languages.append(SuggestionOtherLanguage())
                } label: {
                    Label("Add language", systemImage: "plus.circle.fill")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .hudScreen()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }
}

// MARK: - First-time setup / edit all

struct SuggestionProfileSetupView: View {
    @EnvironmentObject private var profileStore: SuggestionProfileStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var locationHelper = SuggestionLocationHelper()
    @State private var draft = SuggestionUserProfile.empty

    var body: some View {
        ScrollView(showsIndicators: false) {
            SuggestionProfileFormView(profile: $draft, locationHelper: locationHelper)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .hudScreen()
        .navigationTitle("Setup suggestion")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    profileStore.saveProfile(draft)
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }
}

struct SuggestionProfileEditAllView: View {
    @EnvironmentObject private var profileStore: SuggestionProfileStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var locationHelper = SuggestionLocationHelper()
    @State private var draft = SuggestionUserProfile.empty

    var body: some View {
        Group {
            if profileStore.profile != nil {
                ScrollView(showsIndicators: false) {
                    SuggestionProfileFormView(profile: $draft, locationHelper: locationHelper)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .hudScreen()
                .navigationTitle("Edit profile")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    if let p = profileStore.profile {
                        draft = p
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            profileStore.saveProfile(draft)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }
}

// MARK: - List of fields (per-item edit)

struct SuggestionProfileFieldListView: View {
    @EnvironmentObject private var profileStore: SuggestionProfileStore

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                NavigationLink {
                    SuggestionProfileEditAllView()
                        .environmentObject(profileStore)
                } label: {
                    HStack {
                        Image(systemName: "square.and.pencil")
                        Text("Edit entire profile")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HUDTheme.inkMuted)
                    }
                    .foregroundStyle(HUDTheme.accent)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HUDTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)

                ForEach(SuggestionProfileFieldID.allCases) { field in
                    NavigationLink {
                        SuggestionProfileFieldEditorView(field: field)
                            .environmentObject(profileStore)
                    } label: {
                        HUDCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(field.title)
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(HUDTheme.ink)
                                Text(profileStore.profile?.preview(for: field) ?? "—")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(HUDTheme.inkMuted)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .hudScreen()
        .navigationTitle("Your profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Single field editor

struct SuggestionProfileFieldEditorView: View {
    @EnvironmentObject private var profileStore: SuggestionProfileStore
    @Environment(\.dismiss) private var dismiss

    let field: SuggestionProfileFieldID

    @StateObject private var locationHelper = SuggestionLocationHelper()
    @State private var text: String = ""
    @State private var tone: SuggestionTonePreference = .friendly
    @State private var languages: [SuggestionOtherLanguage] = []
    @State private var locationDisplay: String = ""
    @State private var locationAgreed: Bool = false

    var body: some View {
        Group {
            switch field {
            case .otherLanguages:
                SuggestionOtherLanguagesEditor(languages: $languages)
                    .onAppear { languages = profileStore.profile?.otherLanguages ?? [] }
            case .tonePreference:
                ScrollView {
                    HUDCard(padding: 20) {
                        Picker("Tone", selection: $tone) {
                            ForEach(SuggestionTonePreference.allCases) { t in
                                Text(t.displayName).tag(t)
                            }
                        }
                        .pickerStyle(.inline)
                        .tint(HUDTheme.accent)
                    }
                    .padding(20)
                }
                .hudScreen()
                .onAppear { tone = profileStore.profile?.tonePreference ?? .friendly }
            case .currentLocation:
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        HUDCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("HUDini only reads location when you tap detect — not continuous background tracking.")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(HUDTheme.inkMuted)

                                Toggle("Allow location for suggestion context", isOn: $locationAgreed)
                                    .tint(HUDTheme.accent)

                                Button {
                                    if locationAgreed {
                                        locationHelper.requestWhenInUseAccess()
                                    }
                                    locationHelper.detectCurrentLocation()
                                } label: {
                                    HStack {
                                        if locationHelper.isLocating {
                                            ProgressView()
                                        }
                                        Text("Detect current location")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(HUDSecondaryButtonStyle())
                                .disabled(!locationAgreed)

                                if let err = locationHelper.lastErrorMessage {
                                    Text(err)
                                        .font(.system(.caption, design: .rounded))
                                        .foregroundStyle(HUDTheme.rose)
                                }

                                Text("Location (editable)")
                                    .font(.system(.caption, design: .rounded, weight: .semibold))
                                    .foregroundStyle(HUDTheme.inkMuted)
                                TextField("City, area…", text: $locationDisplay, axis: .vertical)
                                    .font(.system(.body, design: .rounded))
                                    .lineLimit(2...6)
                                    .padding(14)
                                    .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(HUDTheme.strokeStrong, lineWidth: 1)
                                    }
                                    .foregroundStyle(HUDTheme.ink)
                            }
                        }
                    }
                    .padding(20)
                }
                .hudScreen()
                .onAppear {
                    locationDisplay = profileStore.profile?.currentLocationDisplay ?? ""
                    locationAgreed = profileStore.profile?.agreedToLocationForSuggestions ?? false
                }
                .onChange(of: locationHelper.lastResolvedDisplay, initial: false) { _, new in
                    guard locationAgreed, let new, !new.isEmpty else { return }
                    locationDisplay = new
                }
            default:
                ScrollView {
                    HUDCard(padding: 16) {
                        TextField("", text: $text, axis: .vertical)
                            .font(.system(.body, design: .rounded))
                            .lineLimit(5...14)
                            .foregroundStyle(HUDTheme.ink)
                    }
                    .padding(20)
                }
                .hudScreen()
                .onAppear { text = stringValue(for: field) }
            }
        }
        .navigationTitle(field.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    apply()
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }

    private func stringValue(for field: SuggestionProfileFieldID) -> String {
        guard let p = profileStore.profile else { return "" }
        switch field {
        case .name: return p.name
        case .nativeLanguage: return p.nativeLanguage
        case .homeCountryCity: return p.homeCountryCity
        case .dietaryRestrictions: return p.dietaryRestrictions
        case .healthConsiderations: return p.healthConsiderations
        case .religionCultural: return p.religionCultural
        case .foodPreferences: return p.foodPreferences
        case .hobbiesInterests: return p.hobbiesInterests
        case .favoriteTopics: return p.favoriteTopics
        case .topicsToAvoid: return p.topicsToAvoid
        case .personalityStyle: return p.personalityStyle
        case .typicalUseCases: return p.typicalUseCases
        case .occupation: return p.occupation
        case .neverSuggestInvolving: return p.neverSuggestInvolving
        default: return ""
        }
    }

    private func apply() {
        switch field {
        case .name:
            profileStore.updateProfile { $0.name = text }
        case .nativeLanguage:
            profileStore.updateProfile { $0.nativeLanguage = text }
        case .otherLanguages:
            profileStore.updateProfile { $0.otherLanguages = languages }
        case .homeCountryCity:
            profileStore.updateProfile { $0.homeCountryCity = text }
        case .dietaryRestrictions:
            profileStore.updateProfile { $0.dietaryRestrictions = text }
        case .healthConsiderations:
            profileStore.updateProfile { $0.healthConsiderations = text }
        case .religionCultural:
            profileStore.updateProfile { $0.religionCultural = text }
        case .foodPreferences:
            profileStore.updateProfile { $0.foodPreferences = text }
        case .hobbiesInterests:
            profileStore.updateProfile { $0.hobbiesInterests = text }
        case .favoriteTopics:
            profileStore.updateProfile { $0.favoriteTopics = text }
        case .topicsToAvoid:
            profileStore.updateProfile { $0.topicsToAvoid = text }
        case .tonePreference:
            profileStore.updateProfile { $0.tonePreference = tone }
        case .personalityStyle:
            profileStore.updateProfile { $0.personalityStyle = text }
        case .typicalUseCases:
            profileStore.updateProfile { $0.typicalUseCases = text }
        case .occupation:
            profileStore.updateProfile { $0.occupation = text }
        case .neverSuggestInvolving:
            profileStore.updateProfile { $0.neverSuggestInvolving = text }
        case .currentLocation:
            profileStore.updateProfile {
                $0.currentLocationDisplay = locationDisplay
                $0.agreedToLocationForSuggestions = locationAgreed
                if let lat = locationHelper.lastResolvedLatitude, let lon = locationHelper.lastResolvedLongitude {
                    $0.lastKnownLatitude = lat
                    $0.lastKnownLongitude = lon
                }
            }
        }
    }
}
