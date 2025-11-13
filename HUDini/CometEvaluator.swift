import Foundation

struct CometEvaluator {
    struct Configuration {
        let endpoint: URL
        let apiKey: String
        let timeout: TimeInterval

        init(endpoint: URL, apiKey: String, timeout: TimeInterval = 15) {
            self.endpoint = endpoint
            self.apiKey = apiKey
            self.timeout = timeout
        }
    }

    private let config: Configuration
    private let urlSession: URLSession

    init(config: Configuration, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    static func makeDefault(bundle: Bundle = .main) -> CometEvaluator? {
        let endpointString = bundle.object(forInfoDictionaryKey: "HFCometEndpoint") as? String
        let apiKey = bundle.object(forInfoDictionaryKey: "HFCometAPIKey") as? String

        var finalEndpoint: URL?
        if let endpointString, let url = URL(string: endpointString) {
            finalEndpoint = url
        }

        if finalEndpoint == nil, let envEndpoint = ProcessInfo.processInfo.environment["HF_COMET_ENDPOINT"], let url = URL(string: envEndpoint) {
            finalEndpoint = url
        }

        var finalKey: String?
        if let apiKey, !apiKey.isEmpty {
            finalKey = apiKey
        } else if let envKey = ProcessInfo.processInfo.environment["HF_COMET_API_KEY"], !envKey.isEmpty {
            finalKey = envKey
        }

        guard let endpoint = finalEndpoint, let key = finalKey else {
            return nil
        }

        return CometEvaluator(config: Configuration(endpoint: endpoint, apiKey: key))
    }

    func evaluate(source: String, hypothesis: String, reference: String) async throws -> Double {
        let requestBody = HuggingFaceRequest(
            inputs: .init(
                source: source,
                translation: hypothesis,
                references: [reference]
            )
        )

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = config.timeout
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.other("COMET: Invalid response")
        }

        guard (200..<300).contains(http.statusCode) else {
            if let errorMessage = try? JSONDecoder().decode(HuggingFaceErrorResponse.self, from: data).error {
                throw TranslationError.other("COMET: \(errorMessage)")
            }
            throw TranslationError.other("COMET HTTP \(http.statusCode)")
        }

        if let decoded = try? JSONDecoder().decode(HuggingFaceScoreResponse.self, from: data).score {
            return decoded
        }
        if let array = try? JSONDecoder().decode([HuggingFaceScoreResponse].self, from: data).first?.score {
            return array
        }
        if let direct = try? JSONDecoder().decode(Double.self, from: data) {
            return direct
        }

        throw TranslationError.other("COMET: Unable to parse score")
    }
}

private struct HuggingFaceRequest: Encodable {
    struct Inputs: Encodable {
        let source: String
        let translation: String
        let references: [String]
    }
    let inputs: Inputs
}

private struct HuggingFaceScoreResponse: Decodable {
    let score: Double
}

private struct HuggingFaceErrorResponse: Decodable {
    let error: String
}

