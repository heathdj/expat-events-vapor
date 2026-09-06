import Fluent
import Vapor
import ExpatEventsAPI

/// Free: 5 active hosted events, 5 attendees/event, public only.
/// Premium: unlimited events, 100 attendees by default, private events
/// allowed, one group (architecture §11). Every check here has a
/// server-side enforcement path independent of the UI (§5 known-risk #8:
/// "a Free user shouldn't reach Premium-gated actions via a raw route").
struct PlanLimitsService {
    let db: Database

    static let freeMaxActiveEvents = 5
    static let freeMaxAttendeesPerEvent = 5
    static let premiumDefaultAttendeeLimit = 100
    static let freeMaxGroupModerators = 5

    func subscription(for userID: UUID) async throws -> Subscription {
        if let sub = try await Subscription.query(on: db).filter(\.$user.$id == userID).first() {
            return sub
        }
        // Every user is seeded with a Free Subscription in AuthService;
        // this is a defensive fallback against data drift, not the happy path.
        let sub = Subscription(userID: userID, plan: .free, status: .active)
        try await sub.save(on: db)
        return sub
    }

    /// M4 acceptance criterion #1: a Free user can create up to 5 active
    /// events; the 6th attempt is rejected with a clear plan-limit error.
    func assertCanCreateEvent(hostUserID: UUID) async throws {
        let sub = try await subscription(for: hostUserID)
        guard !sub.isActivePremium else { return }

        let activeCount = try await Event.query(on: db)
            .filter(\.$hostUser.$id == hostUserID)
            .filter(\.$isCancelled == false)
            .count()

        guard activeCount < Self.freeMaxActiveEvents else {
            throw APIError.planLimit(
                "Free accounts can host up to \(Self.freeMaxActiveEvents) active events. Upgrade to Premium for unlimited events."
            )
        }
    }

    /// M4 acceptance criterion #3: a Free user cannot set an event to
    /// `private` — rejected server-side even if the UI is bypassed.
    /// Group-hosted events are exempt: the group's owner already had to be
    /// Premium to create the group in the first place (M6).
    func assertCanSetVisibility(_ visibility: EventVisibility, hostUserID: UUID?) async throws {
        guard visibility == .private, let hostUserID else { return }
        let sub = try await subscription(for: hostUserID)
        guard sub.isActivePremium else {
            throw APIError.planLimit("Private events require a Premium plan.")
        }
    }

    /// The effective attendee cap for an event: an explicit `attendeeLimit`
    /// wins; otherwise it falls back to the host's plan default.
    func attendeeLimit(for event: Event) async throws -> Int {
        if let explicit = event.attendeeLimit {
            return explicit
        }
        if let hostUserID = event.$hostUser.id {
            let sub = try await subscription(for: hostUserID)
            return sub.isActivePremium ? Self.premiumDefaultAttendeeLimit : Self.freeMaxAttendeesPerEvent
        }
        // Group-hosted: the group's owner must be Premium (M6), so the
        // Premium default applies.
        return Self.premiumDefaultAttendeeLimit
    }

    /// M4 acceptance criterion #2: a Free-tier event accepts up to 5
    /// attendees; the 6th join attempt is rejected the same way as #1.
    func assertCanJoin(event: Event) async throws {
        let limit = try await attendeeLimit(for: event)
        let currentCount = try await EventAttendee.query(on: db)
            .filter(\.$event.$id == event.requireID())
            .count()
        guard currentCount < limit else {
            throw APIError.planLimit("This event is full (\(limit) attendee limit).")
        }
    }

    /// M6: only an active-Premium user may create a group, and only one
    /// group per membership (owned or otherwise) at a time.
    func assertCanCreateGroup(ownerID: UUID) async throws {
        let sub = try await subscription(for: ownerID)
        guard sub.isActivePremium else {
            throw APIError.planLimit("Creating a group requires a Premium plan.")
        }
        let existing = try await GroupMembership.query(on: db)
            .filter(\.$user.$id == ownerID)
            .filter(\.$role == .owner)
            .count()
        guard existing == 0 else {
            throw APIError.planLimit("You already own a group — only one group per membership is allowed.")
        }
    }
}
