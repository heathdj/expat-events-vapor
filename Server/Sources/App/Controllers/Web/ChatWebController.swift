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
    }

    func boot(routes: RoutesBuilder) throws {
        // M5 acceptance criterion #4: an unauthenticated visitor cannot
        // open a chat socket for any event — guardMiddleware() throws
        // before the socket ever upgrades, same as EventWebController's
        // write routes.
        let authenticated = routes.grouped(User.sessionAuthenticator(), User.guardMiddleware(), NotSuspendedMiddleware())

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
        ws.onText { _, text in
            await Self.receive(text: text, eventID: eventID, userID: userID, req: req, registry: registry)
        }

        ws.onClose.whenComplete { _ in
            Task {
                await registry.leave(eventID: eventID, connectionID: connectionID)
            }
        }
    }

    private static func receive(text: String, eventID: UUID, userID: UUID, req: Request, registry: ChatRoomRegistry) async {
        do {
            let data = Data(text.utf8)
            let sendRequest = try JSONDecoder().decode(SendChatMessageRequest.self, from: data)
            let message = try await ChatService(db: req.db).send(sendRequest, eventID: eventID, userID: userID)
            let dto = try message.toDTO()
            let html = try await Self.render(req: req, dto: dto)
            await registry.broadcast(html, to: eventID)
        } catch {
            // Doesn't send a `.error` envelope back — M5's client is
            // HTML-only (see ChatRoomRegistry's doc comment), and there's
            // no agreed-on HTML shape yet for an inline chat-send error.
            // A malformed/rejected send just doesn't appear, which is a
            // silent failure worth improving in a follow-up, not a
            // security concern (ChatService.send already independently
            // re-validates everything regardless of what the client sent).
            req.logger.error("Chat message decode/send failed: \(error)")
        }
    }

    private static func render(req: Request, dto: ChatMessageDTO) async throws -> String {
        let view = try await req.view.render("partials/chat-message-oob", MessageContext(message: dto))
        return String(buffer: view.data)
    }
}
