import Foundation

// MARK: - CachedEntry

struct CachedEntry: Codable {
    let query: String       // normalized (lowercased, trimmed) user query
    let response: String    // the assistant's full response text
    let timestamp: Date
    let eventIDs: [String]  // event identifiers referenced in this response
}

// MARK: - ResponseCacheService

/// Persists recent query→response pairs to disk and provides keyword-based search.
///
/// Purpose: Foundation Models has a 4,096-token context window. Without external
/// memory, the live session transcript fills up quickly with repeated calendar data.
/// The SearchCacheTool calls this service so the LLM can recall past responses
/// from disk rather than keeping them in the active transcript.
@MainActor
class ResponseCacheService {
    private var cache: [CachedEntry] = []
    private let maxEntries = 50
    private let cacheTTLDays = 7
    private let cacheURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        cacheURL = docs.appendingPathComponent("voxi_cache.json")
        load()
    }

    // MARK: - Write

    /// Call this after every successful LLM response to persist it.
    func store(query: String, response: String, eventIDs: [String] = []) async {
        let entry = CachedEntry(
            query: normalized(query),
            response: response,
            timestamp: Date(),
            eventIDs: eventIDs
        )
        // Avoid exact duplicates: drop any prior entry with the same normalized query
        cache.removeAll { $0.query == entry.query }
        cache.append(entry)

        // Keep only the most recent maxEntries
        if cache.count > maxEntries {
            cache = Array(cache.suffix(maxEntries))
        }
        save()
    }

    // MARK: - Search

    /// Returns up to 3 cached entries whose query overlaps the given search terms.
    /// Uses simple word-intersection scoring — no embeddings needed for MVP.
    func search(query: String) async -> [CachedEntry] {
        let searchWords = words(from: query)
        guard !searchWords.isEmpty else { return [] }

        let scored: [(entry: CachedEntry, score: Int)] = cache.compactMap { entry in
            let entryWords = words(from: entry.query + " " + entry.response)
            let overlap = searchWords.filter { entryWords.contains($0) }.count
            return overlap > 0 ? (entry, overlap) : nil
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map(\.entry)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([CachedEntry].self, from: data)
        else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -cacheTTLDays, to: Date())!
        cache = decoded.filter { $0.timestamp > cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Helpers

    private func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func words(from text: String) -> Set<String> {
        let stopWords: Set<String> = ["the", "a", "an", "is", "are", "was", "i", "my", "me",
                                      "do", "have", "what", "when", "how", "any", "on", "for"]
        return Set(
            text.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        )
    }
}
