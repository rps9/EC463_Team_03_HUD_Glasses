import SwiftUI

struct TranslationTesterView: View {
    @StateObject private var tester = TranslationTester()
    @FocusState private var isSourceFocused: Bool
    @FocusState private var isReferenceFocused: Bool

    private let pool: [TranslationSample] = [
        .init(source: "請問今天下午的會議幾點開始？", reference: "What time does the meeting start this afternoon?"),
        .init(source: "這份文件請先複印三份再交給主管。", reference: "Please make three copies of this document before handing it to the supervisor."),
        .init(source: "如果有任何問題請立即通知我。", reference: "If there are any issues, let me know immediately."),
        .init(source: "明天的天氣預報說會下雨，記得帶傘。", reference: "The weather forecast says it will rain tomorrow, so remember to bring an umbrella."),
        .init(source: "我們需要在週五之前完成這個專案。", reference: "We need to finish this project before Friday."),
        .init(source: "請把最新的設計圖上傳到共享資料夾。", reference: "Please upload the latest design files to the shared folder."),
        .init(source: "你可以幫我確認一下投影機的設定嗎？", reference: "Can you help me check the projector settings?"),
        .init(source: "午餐時間我們去附近的新餐廳試試看。", reference: "Let’s try the new restaurant nearby at lunchtime."),
        .init(source: "請在報表上標註所有關鍵數據。", reference: "Please mark all the key data on the report."),
        .init(source: "謝謝你今天的協助，辛苦了。", reference: "Thank you for your help today; I really appreciate it.")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Translation Testing")
                    .font(.headline)

                Group {
                    sectionTitle("Source language")
                    languagePicker(selection: $tester.sourceLanguageCode, options: TranslationLanguages.sourceOptions)
                }

                Group {
                    sectionTitle("Target language")
                    languagePicker(selection: $tester.targetLanguageCode, options: TranslationLanguages.targetOptions)
                }

                Group {
                    sectionTitle("Text to translate")
                    TextEditor(text: $tester.sourceText)
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .focused($isSourceFocused)
                }

                Group {
                    sectionTitle("Reference translation (optional)")
                    TextEditor(text: $tester.referenceTranslation)
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .focused($isReferenceFocused)
                }

                Group {
                    sectionTitle("Translation result")
                    ScrollView {
                        Text(tester.translatedText.isEmpty ? "…" : tester.translatedText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 100)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 12) {
                    Button("New sentence") { tester.pickRandomSentence(from: pool) }
                        .buttonStyle(.bordered)
                        .disabled(tester.isRunning)

                    Button(tester.isRunning ? "Translating…" : "Run test") { tester.runTest() }
                        .buttonStyle(.borderedProminent)
                        .disabled(tester.isRunning)

                    Button("Reset stats") { tester.resetStats() }
                        .buttonStyle(.bordered)
                        .disabled(tester.isRunning || tester.runs == 0)

                    Button("Clear") { tester.clear() }
                        .buttonStyle(.bordered)
                        .disabled(tester.isRunning)
                }

                if let metrics = tester.lastMetrics {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last run").font(.subheadline).bold()
                        Text("Translate time: \(formatMS(metrics.durationMS))")
                        if let comet = metrics.cometScore {
                            if let source = metrics.cometSource {
                                Text("COMET (\(source.displayName)): \(formatScore(comet))")
                            } else {
                                Text("COMET: \(formatScore(comet))")
                            }
                        } else {
                            Text("COMET: —")
                        }
                        Text("Output: “\(metrics.translated)”")
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Session averages (\(tester.runs) run\(tester.runs == 1 ? "" : "s"))")
                        .font(.subheadline).bold()
                    Text("Avg translate time: \(formatMS(tester.avgDurationMS))")
                    if let avgComet = tester.avgCometScore {
                        if tester.cometSamples > 0 {
                            Text("Avg COMET (n=\(tester.cometSamples)): \(formatScore(avgComet))")
                        } else {
                            Text("Avg COMET: \(formatScore(avgComet))")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !tester.status.isEmpty {
                    Text(tester.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)
            }
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture {
            isSourceFocused = false
            isReferenceFocused = false
        }
    }

    private func languagePicker(selection: Binding<String>, options: [TranslationLanguageOption]) -> some View {
        Picker("Language", selection: selection) {
            ForEach(options) { option in
                Text(option.name).tag(option.code)
            }
        }
        .pickerStyle(.menu)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatMS(_ x: Double) -> String {
        if x.isNaN { return "—" }
        return String(format: "%.0f ms", x)
    }

    private func formatScore(_ score: Double) -> String {
        let clamped = max(0, min(1, score))
        return String(format: "%.3f", clamped)
    }
}

#Preview { TranslationTesterView() }

