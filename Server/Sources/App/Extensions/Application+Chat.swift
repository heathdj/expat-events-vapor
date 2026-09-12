import Vapor

/// Gives every request a way to reach the single, process-wide
/// `ChatRoomRegistry` (architecture §8, M5) without threading it through
/// every controller initializer — same shape as Vapor's own `app.sessions`/
/// `app.jwt`. Explicitly initialized once in `configure.swift`
/// (`app.chatRoomRegistry = ChatRoomRegistry()`) rather than lazily
/// created on first read, so there's no read/create race the way a
/// lazy-init-into-storage pattern would have under concurrent requests.
extension Application {
    private struct ChatRoomRegistryKey: StorageKey {
        typealias Value = ChatRoomRegistry
    }

    var chatRoomRegistry: ChatRoomRegistry {
        get {
            guard let existing = self.storage[ChatRoomRegistryKey.self] else {
                fatalError("ChatRoomRegistry not configured — call configureChat(app) (or set app.chatRoomRegistry directly) before using it.")
            }
            return existing
        }
        set {
            self.storage[ChatRoomRegistryKey.self] = newValue
        }
    }
}

extension Request {
    var chatRoomRegistry: ChatRoomRegistry {
        self.application.chatRoomRegistry
    }
}
