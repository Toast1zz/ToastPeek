import Foundation
import Combine

/// A generation belongs to both a query and engine. Even a transport that ignores
/// cancellation cannot publish a response from a superseded request.
@MainActor
final class SearchSuggestions: ObservableObject {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    @Published private(set) var items: [String] = []
    private(set) var query = ""
    private var generation: UInt = 0
    private var task: Task<Void, Never>?
    private let transport: Transport
    private let debounceNanoseconds: UInt64

    init(debounceNanoseconds: UInt64 = 120_000_000,
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.debounceNanoseconds = debounceNanoseconds
        self.transport = transport
    }

    func items(for query: String) -> [String] {
        self.query == query.trimmingCharacters(in: .whitespacesAndNewlines) ? items : []
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        items = []
        query = ""
    }

    func update(query: String, engine: SearchEngine, enabled: Bool) {
        cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = q
        guard enabled, !q.isEmpty, !URLResolver.looksLikeURL(q), let template = engine.suggestTemplate,
              let url = URL(string: template.replacingOccurrences(of: "%@", with: URLResolver.encodeQueryValue(q))) else { return }
        let token = generation
        let transport = transport
        let delay = debounceNanoseconds
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                var request = URLRequest(url: url, timeoutInterval: 4)
                request.httpShouldHandleCookies = false
                let (data, response) = try await transport(request)
                try Task.checkCancellation()
                guard self?.generation == token,
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                      json.count > 1, let returnedQuery = json[0] as? String,
                      returnedQuery.caseInsensitiveCompare(q) == .orderedSame,
                      let list = json[1] as? [String] else { return }
                self?.items = Array(list.filter { !$0.isEmpty && $0.lowercased() != q.lowercased() }.prefix(4))
            } catch {
                // Starting a request already cleared its predecessor's results.
            }
        }
    }
}
