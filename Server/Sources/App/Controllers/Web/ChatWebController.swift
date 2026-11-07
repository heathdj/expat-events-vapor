import Fluent
import Vapor
import ExpatEventsAPI

/// The WebSocket endpoint for per-event chat (architecture §8, M5). Kept
/// separate from `EventWebController`: the connect-time authorization
/// here (session auth + `assertVisible`) mirrors that controller's
/// `authenticated` route group, but the WebSocket upgrade lifecycle
/// (`shouldUpgrade`/`onUpgrade`, no full-page Leaf rendering, no
/// `HX-Request` branching) is different enough in shape that folding it
/// into `EventWebController` would mostly add noise there.
struct ChatWebController: RouteCollection {
    /// Leaf render context for one live-broadcast message;
    /// `partials/chat-message-oob.leaf` is the template it renders (see
    /// that partial's own doc comment for why the *page* load's history
    /// loop duplicates this same markup inline instead of sharing it via
    /// `#extend`). Not used for history replay — `handle` below
    /// deliberately doesn't replay history over the socket; see its doc
    /// comment.
    private struct MessageContext: Encodable {
        let message: ChatMessageDTO
        /// Event detail PR: the same row fields the page's history uses.
        let row: EventWebController.ChatRow
    }

    func boot(routes: RoutesBuilder) throws {
        // M5 acceptance criterion #4: an unauthenticated visitor cannot
        // open a chat socket for any event — guardMiddleware() throws
        // before the socket ever upgrades, same as EventWebController's
        // write routes.
        let authenticated = routes.grouped(User.activeSessionAuthenticator(), User.guardMiddleware(), NotSuspendedMiddleware())

        authenticated.webSocket("events", ":eventID", "chat", "ws", shouldUpgrade: { req in
            try await Self.assertCanOpenSocket(req)
            return [:]
        }, onUpgrade: { req, ws in
            await Self.handle(req: req, ws: ws)
        })
    }

    /// M5 acceptance criterion #5: a signed-in non-member of a private
    /// group event's hosting group is rejected here exactly like a
    /// stranger would be from `EventWebController.detail()` — same
    /// `EventService.assertVisible` call, same `.notFound` semantics (a
    /// non-member can't even confirm the event exists by probing the id).
    ///
    /// NOTE: the exact HTTP response a rejected upgrade actually produces
    /// (a plain non-101 status vs. whatever NIOWebSocketServerUpgrader
    /// substitutes when `shouldUpgrade` throws) hasn't been confirmed
    /// against a real client — genuinely hard to verify without one,
    /// similar in spirit to the web-path 500-vs-404 gap already tracked
    /// in WARNINGS.md/MILESTONES.md. What IS enforced either way: the
    /// socket never upgrades, so no history and no live broadcast ever
    /// reach a rejected caller. Worth a real browser/wscat check at the
    /// human server-checkpoint for this milestone.
    private static func assertCanOpenSocket(_ req: Request) async throws {
        let user = try req.auth.require(User.self)
        guard let idString = req.parameters.get("eventID"), let eventID = UUID(uuidString: idString),
              let event = try await EventService(db: req.db).find(eventID)
        else {
            throw Abort(.notFound)
        }
        try await ChatService(db: req.db).assertCanAccessChat(event, requesterID: try user.requireID())
    }

    /// Runs for the lifetime of one open socket. `req.auth`/`req.parameters`
    /// are still valid here — captured from the same request `shouldUpgrade`
    /// already validated above — so there's no need to re-authenticate or
    /// re-check visibility per message; `ChatService.send` independently
    /// persists and validates reply-depth regardless of what happened at
    /// connect time.
    private static func handle(req: Request, ws: WebSocket) async {
        guard let user = req.auth.get(User.self), let userID = try? user.requireID(),
              let idString = req.parameters.get("eventID"), let eventID = UUID(uuidString: idString)
        else {
            try? await ws.close()
            return
        }

        let registry = req.application.chatRoomRegistry
        let connectionID = await registry.join(eventID: eventID, userID: userID, socket: ws)

        // Deliberately does NOT replay history over the socket on connect.
        // An earlier version did (reasoning: "a client that reconnects
        // without a full page reload still sees the full thread"), but a
        // human server-checkpoint caught the real consequence: htmx's
        // ws-connect opens a fresh socket on every full page load, and
        // EventWebController.detail's chatHistory has *already* rendered
        // that same history straight into the page for that same load —
        // so replaying it again here duplicated every message on every
        // ordinary reload, not just some rare drop-and-reconnect case.
        // M5 acceptance criterion #6 ("reloading... still shows full
        // history") is fully satisfied by that server-rendered page load
        // alone; this socket's job from here on is strictly new messages
        // sent from this point forward, not a history replay.
        ws.onText { socket, text in
            await Self.receive(text: text, eventID: eventID, userID: userID, req: req, registry: registry, socket: socket)
        }

        ws.onClose.whenComplete { _ in
            Task {
                await registry.leave(eventID: eventID, connectionID: connectionID)
            }
        }
    }

    private static func receive(text: String, eventID: UUID, userID: UUID, req: Request, registry: ChatRoomRegistry, socket: WebSocket) async {
        do {
            let data = Data(text.utf8)
            let sendRequest = try JSONDecoder().decode(SendChatMessageRequest.self, from: data)
            let message = try await ChatService(db: req.db).send(sendRequest, eventID: eventID, userID: userID)
            let dto = try message.toDTO()
            let html = try await Self.render(req: req, dto: dto)
            await registry.broadcast(html, to: eventID)
        } catch let error as APIError {
            // Event detail PR review: a refused message used to vanish
            // silently. The sender (only) gets the reason in the chat box.
            req.logger.notice("Chat message refused: \(error.code)")
            await Self.sendError(error.message, req: req, socket: socket)
        } catch {
            // Anything else (a malformed frame, a database error): the
            // sender gets a generic line in the chat box (HTML, like the
            // rest of the M5 client; see ChatRoomRegistry's doc comment).
            req.logger.error("Chat message decode/send failed: \(error)")
            await Self.sendError("That message couldn't be sent. Please try again.", req: req, socket: socket)
        }
    }

    private struct ErrorContext: Encodable {
        let message: String
    }

    /// Replaces the chat box's error line (`#chat-error`) for this socket
    /// only.
    private static func sendError(_ message: String, req: Request, socket: WebSocket) async {
        guard let view = try? await req.view.render("partials/chat-error-oob", ErrorContext(message: message)) else { return }
        try? await socket.send(String(buffer: view.data))
    }

    private static func render(req: Request, dto: ChatMessageDTO) async throws -> String {
        // A reply names the message it answers.
        var replyToName: String?
        if let parentID = dto.parentID, let parent = try await ChatMessage.query(on: req.db).filter(\.$id == parentID).with(\.$user).first() {
            replyToName = parent.user.displayName
        }
        let row = EventWebController.chatRow(dto, replyToName: replyToName)
        let view = try await req.view.render("partials/chat-message-oob", MessageContext(message: dto, row: row))
        return String(buffer: view.data)
    }
}
