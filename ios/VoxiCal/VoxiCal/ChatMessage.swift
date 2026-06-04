import Foundation

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp = Date()
}
