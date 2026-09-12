import Fluent
import Vapor
import ExpatEventsAPI

/// Used by the WebSocket route and by `EventWebController`'s history read
/// on page load. Shaped after `EventService`'s "one service, both surfaces"
/// pattern (architecture §3, §8, M5) so that a future `/api/v1` chat
/// surface can reuse it directly — no such route exists yet in this
/// milestone, only the web path does.
struct ChatService {
    let db: Database

    /// Connect-time / send-time authorization (M5 acceptance criteria #4,
    /// #5): reuses `EventService.assertVisible` so a chat socket is exactly
    /// as restricted as the event page itself — an unauthenticated visitor,
    /// or a signed-in non-member of a private group event's hosting group,
    /// gets the same rejection either way. Deliberately not reimplemented
    /// here: one rule, enforced once, shared by both surfaces (same reason
    /// `EventService` itself is shared rather than duplicated per M4).
    func assertCanAccessChat(_ event: Event, requesterID: UUID?) async throws {
        try await EventService(db: db).assertVisible(event, to: requesterID)
    }

    /// M5 acceptance criterion #2: persist before anything else. The
    /// caller (the WebSocket route) broadcasts the returned message via
    /// `ChatRoomRegistry` immediately after this returns — persistence and
    /// broadcast are two separate steps on purpose, so a broadcast can
    /// never go out for a message that didn't actually save.
    ///
    /// Known narrow gap (independent review, post the history-replay-
    /// removal fix): a message sent in the brief window between a
    /// viewer's page finishing its server-rendered history and that same
    /// viewer's own socket completing its handshake is neither in their
    /// rendered page nor delivered live to them — only a later reload
    /// picks it up. Accepted rather than reintroducing on-connect replay,
    /// which is what caused the duplicate-message bug this fix resolved.
    ///
    /// `parentID`, if given, must reference an existing message on this
    /// *same* event — M5 acceptance criterion #3 is "one level of reply
    /// threading," so a reply-to-a-reply is deliberately rejected here
    /// rather than silently allowed and left for the client to render
    /// however it likes.
    func send(_ request: SendChatMessageRequest, eventID: UUID, userID: UUID) async throws -> ChatMessage {
        if let parentID = request.parentID {
            guard let parent = try await ChatMessage.find(parentID, on: db), parent.$event.id == eventID else {
                throw APIError.notFound
            }
            guard parent.$parent.id == nil else {
                throw APIError(code: "reply_too_deep", message: "Replies can only be one level deep.")
            }
        }

        let message = ChatMessage(eventID: eventID, userID: userID, parentID: request.parentID, text: request.text)
        try await message.save(on: db)
        try await message.$user.load(on: db)
        return message
    }

    /// M5 acceptance criterion #2/#6: the full persisted history, oldest
    /// first — this is what EventWebController.detail renders straight
    /// into the page on every load (the socket itself no longer replays
    /// history; see the doc comment on `send` above for why), so a client
    /// that never sees a single WebSocket frame still sees exactly the
    /// same conversation.
    func history(eventID: UUID) async throws -> [ChatMessage] {
        try await ChatMessage.query(on: db)
            .filter(\.$event.$id == eventID)
            .with(\.$user)
            .sort(\.$createdAt, .ascending)
            .all()
    }
}

extension ChatMessage {
    /// `user` must already be eager-loaded (`send`/`history` above both do
    /// this) — a crash here means a caller skipped that, which is a bug at
    /// the call site, not something to silently paper over with an
    /// optional/placeholder display name.
    func toDTO() throws -> ChatMessageDTO {
        ChatMessageDTO(
            id: try requireID(),
            eventID: $event.id,
            userID: $user.id,
            displayName: user.displayName,
            photoURL: user.photoURL,
            parentID: $parent.id,
            text: text,
            createdAt: createdAt ?? Date()
        )
    }
}
