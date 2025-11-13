import Foundation
import Combine

struct TranslationTestMetrics {
    enum CometScoreSource: String {
        case api
        case heuristic

        var displayName: String {
            switch self {
            case .api: return "API"
            case .heuristic: return "Heuristic"
            }
        }
    }

    let translated: String
    let durationMS: Double
    let cometScore: Double?
    let cometSource: CometScoreSource?
}

struct TranslationSample {
    let source: String
    let reference: String
}
@MainActor
final class TranslationTester: ObservableObject {
    @Published var sourceText: String = ""
    @Published var translatedText: String = ""
    @Published var status: String = ""
    @Published var isRunning: Bool = false

    @Published var lastMetrics: TranslationTestMetrics?
    @Published var runs: Int = 0
    @Published var avgDurationMS: Double = 0

    @Published var sourceLanguageCode: String = TranslationLanguages.autoCode
    @Published var targetLanguageCode: String = "es"
    @Published var referenceTranslation: String = ""

    private let service: TranslationService
    private let cometEvaluator: CometEvaluator?

    @Published private(set) var avgCometScore: Double? = nil
    @Published private(set) var cometSamples: Int = 0
    private var cometSampleCount: Int = 0

    init(service: TranslationService? = nil) {
        if let service {
            self.service = service
        } else if #available(iOS 26.0, *) {
            self.service = AppleTranslationService()
        } else {
            self.service = UnsupportedAppleTranslationService()
        }
        cometEvaluator = CometEvaluator.makeDefault()
    }

    func pickRandomSentence(from pool: [String]) {
        guard !pool.isEmpty else { return }
        sourceText = pool.randomElement()!
        translatedText = ""
        lastMetrics = nil
        status = "Ready"
        referenceTranslation = ""
    }

    func pickRandomSentence(from samples: [TranslationSample]) {
        guard !samples.isEmpty else { return }
        let sample = samples.randomElement()!
        sourceText = sample.source
        translatedText = ""
        referenceTranslation = sample.reference
        lastMetrics = nil
        status = "Ready"
        sourceLanguageCode = "zh-Hant"
        if targetLanguageCode == "es" || targetLanguageCode == TranslationLanguages.autoCode {
            targetLanguageCode = "en"
        }
    }

    func runTest() {
        guard !isRunning else { return }

        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Enter text to translate"
            return
        }

        isRunning = true
        translatedText = ""
        status = "Translating…"

        let selectedSource = sourceLanguageCode == TranslationLanguages.autoCode ? nil : sourceLanguageCode

        Task {
            let started = Date()
            do {
                let output = try await service.translate(
                    text: trimmed,
                    source: selectedSource,
                    target: targetLanguageCode
                )
                let duration = Date().timeIntervalSince(started) * 1000.0
                var cometScore: Double?
                var cometSource: TranslationTestMetrics.CometScoreSource?
                let trimmedReference = referenceTranslation.trimmingCharacters(in: .whitespacesAndNewlines)

                if let evaluator = cometEvaluator, !trimmedReference.isEmpty {
                    status = "Completed (COMET evaluating…)"
                    do {
                        let apiScore = try await evaluator.evaluate(
                            source: trimmed,
                            hypothesis: output,
                            reference: trimmedReference
                        )
                        cometScore = apiScore
                        cometSource = .api
                        status = "Completed"
                    } catch {
                        status = "Completed (COMET API failed: \(error.localizedDescription))"
                        if let fallback = computeHeuristicCometScore(candidate: output, reference: trimmedReference) {
                            cometScore = fallback
                            cometSource = .heuristic
                        }
                    }
                } else {
                    let fallback = computeHeuristicCometScore(candidate: output, reference: trimmedReference)
                    if let fallback {
                        cometScore = fallback
                        cometSource = .heuristic
                    }
                    status = "Completed"
                }

                let metrics = TranslationTestMetrics(
                    translated: output,
                    durationMS: duration,
                    cometScore: cometScore,
                    cometSource: cometSource
                )

                translatedText = output
                lastMetrics = metrics
                runs += 1
                avgDurationMS = ((avgDurationMS * Double(runs - 1)) + metrics.durationMS) / Double(runs)
                if let comet = cometScore {
                    let currentTotal = (avgCometScore ?? 0) * Double(cometSampleCount)
                    cometSampleCount += 1
                    avgCometScore = (currentTotal + comet) / Double(cometSampleCount)
                    cometSamples = cometSampleCount
                }
                status = "Completed"
            } catch {
                translatedText = ""
                if let err = error as? LocalizedError, let description = err.errorDescription {
                    status = description
                } else {
                    status = "Translation failed"
                }
            }
            isRunning = false
        }
    }

    func resetStats() {
        runs = 0
        avgDurationMS = 0
        avgCometScore = nil
        cometSampleCount = 0
        cometSamples = 0
        lastMetrics = nil
        status = "Cleared stats"
    }

    func clear() {
        sourceText = ""
        translatedText = ""
        lastMetrics = nil
        status = ""
        referenceTranslation = ""
    }

    private func computeHeuristicCometScore(candidate: String, reference: String) -> Double? {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty, !trimmedReference.isEmpty else {
            return nil
        }

        let hypTokens = tokenize(trimmedCandidate)
        let refTokens = tokenize(trimmedReference)
        guard !hypTokens.isEmpty, !refTokens.isEmpty else { return nil }

        var referenceCounts: [String: Int] = [:]
        for token in refTokens {
            referenceCounts[token, default: 0] += 1
        }
        var matches = 0
        for token in hypTokens {
            if let count = referenceCounts[token], count > 0 {
                matches += 1
                referenceCounts[token] = count - 1
            }
        }

        let precision = Double(matches) / Double(hypTokens.count)
        let recall = Double(matches) / Double(refTokens.count)
        guard precision > 0 || recall > 0 else { return 0 }

        let f1 = (2 * precision * recall) / (precision + recall)
        return f1
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}\\s]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}

