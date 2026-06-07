import FoundationModels

struct SearchArchiveTool: Tool, @unchecked Sendable {
    let name = "searchConversationHistory"
    let description = "Search archived conversation history for something discussed earlier in this session."

    @Generable
    struct Arguments {
        @Guide(description: "Keyword or phrase to find in the archived conversation history")
        var query: String
    }

    let archive: ConversationArchive

    func call(arguments: Arguments) async throws -> String {
        archive.search(query: arguments.query)
    }
}
