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

    /// An explicit attendee limit set at creation must be at least 1 and no
    /// higher than the host's plan cap: 5 for a Free self-hosted event, 100
    /// (the Premium default) otherwise, including group-hosted events
    /// (`hostUserID` nil), whose owner is Premium by construction (M6).
    /// Without this, a Free host could have lifted their own 5-attendee
    /// cap just by typing a bigger number, since an explicit limit wins
    /// in `attendeeLimit(for:)` below.
    func assertCanSetAttendeeLimit(_ limit: Int, hostUserID: UUID?) async throws {
        guard limit >= 1 else {
            throw APIError(code: "invalid_attendee_limit", message: "The attendee limit must be at least 1.")
        }
        if let hostUserID {
            let sub = try await subscription(for: hostUserID)
            if !sub.isActivePremium {
                guard limit <= Self.freeMaxAttendeesPerEvent else {
                    throw APIError.planLimit("Free accounts can have up to \(Self.freeMaxAttendeesPerEvent) attendees per event. Upgrade to Premium for up to \(Self.premiumDefaultAttendeeLimit).")
                }
                return
            }
        }
        guard limit <= Self.premiumDefaultAttendeeLimit else {
            throw APIError.planLimit("Events can have up to \(Self.premiumDefaultAttendeeLimit) attendees.")
        }
    }

    /// The effective attendee cap for an event: an explicit `attendeeLimit`
    /// wins; otherwise it falls back to the host's plan default.
    ///
    /// An explicit limit is still held to the host's *current* plan cap:
    /// a Premium host who set 100 and later dropped to Free gets 5, the
    /// same as if they'd left it empty (found by the event-basics review;
    /// otherwise one month of Premium bought a permanent 100-person cap).
    func attendeeLimit(for event: Event) async throws -> Int {
        let planCap: Int
        if let hostUserID = event.$hostUser.id {
            let sub = try await subscription(for: hostUserID)
            planCap = sub.isActivePremium ? Self.premiumDefaultAttendeeLimit : Self.freeMaxAttendeesPerEvent
        } else {
            // Group-hosted: the group's owner must be Premium (M6), so the
            // Premium default applies.
            planCap = Self.premiumDefaultAttendeeLimit
        }
        if let explicit = event.attendeeLimit {
            return min(explicit, planCap)
        }
        return planCap
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
