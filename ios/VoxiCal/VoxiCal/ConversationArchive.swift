import Foundation

final class ConversationArchive {
    private let fileManager = FileManager.default
    let sessionID: String

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    private var archiveDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("VoxiCalArchives/\(sessionID)", isDirectory: true)
    }

    func save(_ messages: [ChatMessage]) throws {
        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSinceReferenceDate)
        let fileURL = archiveDirectory.appendingPathComponent("archive_\(timestamp).md")
        try format(messages).write(to: fileURL, atomically: true, encoding: String.Encoding.utf8)
    }

    func search(query: String) -> String {
        guard let files = try? fileManager.contentsOfDirectory(
            at: archiveDirectory,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "md" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        else { return "No archived conversations found." }

        let lowercased = query.lowercased()
        var matches: [String] = []

        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.lowercased().contains(lowercased) {
                let start = max(0, i - 2)
                let end = min(lines.count - 1, i + 4)
                let snippet = lines[start...end].joined(separator: "\n")
                matches.append(snippet)
            }
        }

        guard !matches.isEmpty else { return "No archived content matches '\(query)'." }
        return matches.joined(separator: "\n\n---\n\n")
    }

    func deleteAll() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("VoxiCalArchives", isDirectory: true)
        try? fileManager.removeItem(at: root)
    }

    private func format(_ messages: [ChatMessage]) -> String {
        var lines = ["# VoxiCal Conversation Archive", "**Session:** \(sessionID)", ""]
        for message in messages {
            let role = message.role == .user ? "User" : "VoxiCal"
            lines.append("**\(role):** \(message.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
