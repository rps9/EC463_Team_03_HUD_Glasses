//
//  HUDiniTests.swift
//  HUDiniTests
//
//  Created by Ryan Smith on 10/16/25.
//

import XCTest
import Speech

// MARK: - Test model

struct ASRTestCase: Decodable {
    let file: String            // e.g. "hello_quiet_en.m4a"
    let expected: String        // reference transcript
    let locale: String          // e.g. "en-US"
    let requiresOnDevice: Bool? // set true if you want local only (where supported)
    let maxWer: Double?         // e.g. 0.12 for quiet
    let maxFinalMs: Int?        // e.g. 2500 for final result latency
    let maxFirstPartialMs: Int? // optional: time to first partial
}

// MARK: - WER utilities

fileprivate func normalize(_ s: String) -> [String] {
    // Lowercase, strip punctuation, collapse whitespace
    let lower = s.lowercased()
    let allowed = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
    let cleaned = String(lower.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
    return cleaned
        .replacingOccurrences(of: #"\'"#, with: "", options: .regularExpression)
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
}

fileprivate func levenshteinDistance(_ a: [String], _ b: [String]) -> Int {
    // Classic DP edit distance
    var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0...a.count { dp[i][0] = i }
    for j in 0...b.count { dp[0][j] = j }
    for i in 1...a.count {
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            dp[i][j] = min(
                dp[i - 1][j] + 1,      // deletion
                dp[i][j - 1] + 1,      // insertion
                dp[i - 1][j - 1] + cost // substitution
            )
        }
    }
    return dp[a.count][b.count]
}

fileprivate func wordErrorRate(ref: String, hyp: String) -> Double {
    let r = normalize(ref)
    let h = normalize(hyp)
    if r.isEmpty { return h.isEmpty ? 0.0 : 1.0 }
    let dist = levenshteinDistance(r, h)
    return Double(dist) / Double(r.count)
}

// MARK: - Test case

final class TranscriptionTests: XCTestCase {

    // If your tests don’t run, set the test target’s “Host Application” to HUDini
    // so the app’s Info.plist usage strings are present.
    // Also: Speech recognition may require a real device for some locales.

    func test_ASR_accuracy_and_latency_from_audio_files() throws {
        let bundle = Bundle(for: Self.self)

        // 1) Load test manifest from the test bundle
        guard let manifestURL = bundle.url(forResource: "ASRManifest", withExtension: "json") else {
            XCTFail("Missing ASRManifest.json in test bundle")
            return
        }
        let data = try Data(contentsOf: manifestURL)
        let cases = try JSONDecoder().decode([ASRTestCase].self, from: data)

        // 2) Loop test cases
        for tcase in cases {
            guard let audioURL = bundle.url(forResource: (tcase.file as NSString).deletingPathExtension,
                                            withExtension: (tcase.file as NSString).pathExtension) else {
                XCTFail("Missing audio file \(tcase.file) in test bundle")
                continue
            }

            let locale = Locale(identifier: tcase.locale)
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                XCTFail("Unsupported locale \(tcase.locale)")
                continue
            }

            // Be polite and check availability
            if !recognizer.isAvailable {
                XCTFail("Recognizer unavailable for \(tcase.locale)")
                continue
            }

            let exp = expectation(description: "ASR \(tcase.file)")

            let request = SFSpeechURLRecognitionRequest(url: audioURL)
            request.shouldReportPartialResults = true
            if let forceLocal = tcase.requiresOnDevice, forceLocal {
                request.requiresOnDeviceRecognition = true
            }

            var firstPartialMs: Int?
            var finalMs: Int?
            var hypothesis = ""
            let start = DispatchTime.now()

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    XCTFail("ASR error for \(tcase.file): \(error)")
                    exp.fulfill()
                    return
                }
                guard let result = result else { return }

                // time to first partial
                if firstPartialMs == nil {
                    let now = DispatchTime.now()
                    firstPartialMs = Int(now.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                }

                hypothesis = result.bestTranscription.formattedString

                if result.isFinal {
                    let now = DispatchTime.now()
                    finalMs = Int(now.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    exp.fulfill()
                }
            }

            waitForExpectations(timeout: 60.0)
            task.cancel()

            // 3) Evaluate accuracy (WER)
            let wer = wordErrorRate(ref: tcase.expected, hyp: hypothesis)

            // 4) Print a neat summary in the test log
            let summary = """
            ---- ASR RESULT \(tcase.file) ----
            Locale: \(tcase.locale)
            Expected: \(tcase.expected)
            Hypothesis: \(hypothesis)
            WER: \(String(format: "%.3f", wer))
            First partial: \(firstPartialMs.map(String.init) ?? "n/a") ms
            Final time: \(finalMs.map(String.init) ?? "n/a") ms
            -------------------------------
            """
            print(summary)

            // 5) Assertions with sane defaults if not provided in manifest
            let maxWER = tcase.maxWer ?? 0.20   // your quiet requirement is 0.12; noises can be relaxed
            XCTAssertLessThanOrEqual(wer, maxWER, "WER \(wer) exceeded \(maxWER) for \(tcase.file)")

            if let maxFinal = tcase.maxFinalMs, let fms = finalMs {
                XCTAssertLessThanOrEqual(fms, maxFinal, "Final latency \(fms) ms exceeded \(maxFinal) ms")
            }
            if let maxFirst = tcase.maxFirstPartialMs, let pms = firstPartialMs {
                XCTAssertLessThanOrEqual(pms, maxFirst, "First-partial latency \(pms) ms exceeded \(maxFirst) ms")
            }
        }
    }
}

