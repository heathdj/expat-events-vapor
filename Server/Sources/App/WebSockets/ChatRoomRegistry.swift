import Vapor

/// Holds live WebSocket connections per event (architecture §8, M5): "One
/// channel per event; group-hosted events use the same per-event channel."
/// This is the in-memory registry the architecture doc explicitly scopes
/// to single-process deployment — multi-instance fan-out (Postgres
/// `LISTEN`/`NOTIFY` or Redis pub/sub) is called out there as a later
/// concern, not needed at launch, and deliberately not built here.
///
/// An `actor` (not a class + lock) because every mutation — join, leave,
/// broadcast — needs to see a consistent view of `rooms` with no risk of
/// two connects/disconnects racing each other under concurrent WebSocket
/// traffic; Swift's actor isolation gives that for free without hand-
/// written locking.
///
/// Broadcasts plain `String` payloads, not the shared `ChatEnvelope` type:
/// M5's only client is the web (htmx's `ws` extension), which — per
/// architecture §8 — "renders via server-returned HTML swaps with no
/// hand-written JS," i.e. `ChatWebController` sends pre-rendered Leaf HTML
/// fragments over the socket, not JSON. `ChatEnvelope` stays reserved in
/// `ExpatEventsAPI` for a future native/`/api/v1` WebSocket endpoint
/// ("the SwiftUI app's socket client decodes ChatEnvelope directly") —
/// out of scope for this milestone's stated deliverables (web client
/// only), so deliberately not built here rather than half-built and
/// unverified.
actor ChatRoomRegistry {
    /// One entry per live socket. `id` (not the socket itself) is the
    /// dictionary key because `WebSocket` isn't `Hashable`, and because a
    /// stable connection id is what the route handler needs to hand back
    /// to `leave(eventID:connectionID:)` when the socket closes.
    private struct Connection {
        let id = UUID()
        let userID: UUID
        let socket: WebSocket
    }

    /// eventID -> connectionID -> Connection. A nested dictionary (rather
    /// than a flat `[UUID: Connection]` filtered by eventID on every
    /// broadcast) keeps `broadcast(to:)` — the hot path, called on every
    /// incoming message — O(room size) instead of O(total connections
    /// across every event on the server).
    private var rooms: [UUID: [UUID: Connection]] = [:]

    /// Registers a socket as joined to `eventID`'s room. Returns the
    /// connection id the caller must hold onto and pass back to `leave`
    /// when the socket closes — there's no way to recover it from the
    /// `WebSocket` itself later, since it isn't `Hashable`/`Identifiable`.
    func join(eventID: UUID, userID: UUID, socket: WebSocket) -> UUID {
        let connection = Connection(userID: userID, socket: socket)
        rooms[eventID, default: [:]][connection.id] = connection
        return connection.id
    }

    /// Removes one connection from a room. Safe to call more than once
    /// for the same id (e.g. both an explicit `leave` and the socket's
    /// `onClose` firing) — a miss is a no-op, not an error.
    func leave(eventID: UUID, connectionID: UUID) {
        rooms[eventID]?[connectionID] = nil
        if rooms[eventID]?.isEmpty == true {
            rooms[eventID] = nil
        }
    }

    /// Fans `html` out to every socket currently in `eventID`'s room,
    /// including the sender (the architecture doc's own wording:
    /// "broadcast ... to everyone in the room, including the sender" —
    /// the client renders its own sent message from the broadcast echo
    /// rather than optimistically, so there's exactly one source of truth
    /// for what actually persisted).
    ///
    /// A send failing (socket already gone stale server-side, write to a
    /// half-closed connection, etc.) never throws out of this function —
    /// one dead connection must not stop the broadcast reaching everyone
    /// else, and `onClose`/an explicit `leave` call is what actually
    /// removes it from the registry, not a failed send.
    func broadcast(_ html: String, to eventID: UUID) async {
        guard let connections = rooms[eventID], !connections.isEmpty else { return }
        for connection in connections.values {
            try? await connection.socket.send(html)
        }
    }
}
