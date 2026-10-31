import Fluent
import Vapor
import ExpatEventsAPI

/// Everything the admin site (`/admin`, M10, architecture §12) reads and
/// changes. Shared by `AdminWebController` and, later, `/api/v1/admin`
/// (deferred to M11 by the user's M10 decision), the same
/// one-service-both-surfaces convention as every other domain.
///
/// Every mutating method runs in one transaction with the
/// `AdminAuditLog` row it writes, so an action and its audit row land
/// together or not at all: exactly one row per action (criterion #6).
/// A request that changes nothing (comping a user who's already Premium)
/// is rejected with a message instead, so it writes no row. Audit
/// metadata holds IDs and plan names only, never names or emails, so an
/// erasure (M9) never leaves personal data behind in the log.
struct AdminService {
    let db: Database

    static let pageSize = 25
    static let auditPageSize = 50
    static let maxPage = 10_000
    /// GDPR's one-month deadline for an erasure request, shown as a
    /// countdown on Data requests (architecture §13).
    static let deletionDeadlineDays = 30

    enum Action {
        static let planChanged = "user.plan_changed"
        static let suspended = "user.suspended"
        static let unsuspended = "user.unsuspended"
        static let eventCancelled = "event.cancelled"
        static let ownershipTransferred = "group.ownership_transferred"
        static let deletionProcessed = "deletion_request.processed"
        static let exportProcessed = "data_export_request.processed"
    }

    static func clampedPage(_ page: Int?) -> Int {
        min(max(page ?? 1, 1), maxPage)
    }

    /// The requested page, kept within the pages that exist, so going back
    /// to page 3 after its last row was acted on shows page 2 rather than
    /// an empty table (found by the restyle's review).
    static func existingPage(_ page: Int, total: Int, pageSize: Int) -> Int {
        min(clampedPage(page), max(1, (total + pageSize - 1) / pageSize))
    }

    /// Escapes LIKE wildcards so a search for "50%" or "a_b" matches the
    /// literal text (Postgres' default LIKE escape character is `\`).
    static func likePattern(_ term: String) -> String {
        "%\(escapeLike(term))%"
    }

    static func escapeLike(_ term: String) -> String {
        term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Dashboard

    struct Stats {
        let users: Int
        let premium: Int
        let comped: Int
        let eventsThisWeek: Int
        let groups: Int
        let pendingDeletions: Int
    }

    /// Erased accounts (M9 tombstones) aren't counted as users.
    func stats(now: Date = Date()) async throws -> Stats {
        let users = try await User.query(on: db).filter(\.$erasedAt == nil).count()
        let premium = try await activePremium().count()
        let comped = try await activePremium().filter(\.$grantedByAdmin == true).count()
        let eventsThisWeek = try await Event.query(on: db)
            .filter(\.$date >= now)
            .filter(\.$date < now.addingTimeInterval(7 * 24 * 60 * 60))
            .filter(\.$isCancelled == false)
            .count()
        let groups = try await Group.query(on: db).count()
        let pendingDeletions = try await DeletionRequest.query(on: db).filter(\.$processedAt == nil).count()
        return Stats(users: users, premium: premium, comped: comped, eventsThisWeek: eventsThisWeek, groups: groups, pendingDeletions: pendingDeletions)
    }

    /// Counts for the dashboard's headline cards, each against the
    /// period before it so the card can show a change.
    struct Headline {
        let newAccounts30: Int
        let newAccountsPrevious30: Int
        let eventsNext7: Int
        let eventsLast7: Int
    }

    func headline(now: Date = Date()) async throws -> Headline {
        let day: TimeInterval = 24 * 60 * 60
        let newAccounts30 = try await User.query(on: db)
            .filter(\.$createdAt >= now.addingTimeInterval(-30 * day)).count()
        let previous30 = try await User.query(on: db)
            .filter(\.$createdAt >= now.addingTimeInterval(-60 * day))
            .filter(\.$createdAt < now.addingTimeInterval(-30 * day)).count()
        let next7 = try await Event.query(on: db)
            .filter(\.$date >= now).filter(\.$date < now.addingTimeInterval(7 * day))
            .filter(\.$isCancelled == false).count()
        let last7 = try await Event.query(on: db)
            .filter(\.$date >= now.addingTimeInterval(-7 * day)).filter(\.$date < now)
            .filter(\.$isCancelled == false).count()
        return Headline(newAccounts30: newAccounts30, newAccountsPrevious30: previous30, eventsNext7: next7, eventsLast7: last7)
    }

    /// The activity chart's time ranges: daily for 4 weeks, weekly for 12
    /// weeks, roughly monthly (30-day steps) for a year.
    enum ActivityRange: String, CaseIterable, Sendable {
        case fourWeeks = "4w", twelveWeeks = "12w", year = "1y"

        var bucketCount: Int {
            switch self {
            case .fourWeeks: return 28
            case .twelveWeeks: return 12
            case .year: return 12
            }
        }

        var bucketLength: TimeInterval {
            switch self {
            case .fourWeeks: return 24 * 60 * 60
            case .twelveWeeks: return 7 * 24 * 60 * 60
            case .year: return 30 * 24 * 60 * 60
            }
        }
    }

    struct ActivityBucket {
        let start: Date
        let newAccounts: Int
        let eventsCreated: Int
    }

    /// New accounts and events created per bucket, oldest first, ending now.
    func activity(_ range: ActivityRange, now: Date = Date()) async throws -> [ActivityBucket] {
        let start = now.addingTimeInterval(-range.bucketLength * Double(range.bucketCount))
        let accountDates = try await User.query(on: db).filter(\.$createdAt >= start).all(\.$createdAt).compactMap { $0 }
        let eventDates = try await Event.query(on: db).filter(\.$createdAt >= start).all(\.$createdAt).compactMap { $0 }
        func bucketIndex(_ date: Date) -> Int? {
            let index = Int(date.timeIntervalSince(start) / range.bucketLength)
            return (0..<range.bucketCount).contains(index) ? index : nil
        }
        var accounts = Array(repeating: 0, count: range.bucketCount)
        var events = Array(repeating: 0, count: range.bucketCount)
        for date in accountDates { if let i = bucketIndex(date) { accounts[i] += 1 } }
        for date in eventDates { if let i = bucketIndex(date) { events[i] += 1 } }
        return (0..<range.bucketCount).map { i in
            ActivityBucket(start: start.addingTimeInterval(range.bucketLength * Double(i)), newAccounts: accounts[i], eventsCreated: events[i])
        }
    }

    /// Upcoming, not-cancelled events in the next 30 days, per category,
    /// largest first (categories with none are left out).
    func upcomingEventsByCategory(now: Date = Date()) async throws -> [(EventCategory, Int)] {
        let categories = try await Event.query(on: db)
            .filter(\.$date >= now)
            .filter(\.$date < now.addingTimeInterval(30 * 24 * 60 * 60))
            .filter(\.$isCancelled == false)
            .all(\.$category)
        var counts: [EventCategory: Int] = [:]
        for category in categories { counts[category, default: 0] += 1 }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .map { ($0.key, $0.value) }
    }

    /// Groups whose owner no longer has active Premium (lapsed, or the
    /// owner's account was erased): a group must always have a Premium
    /// owner (architecture §9), so these need an admin to act. One
    /// subscription lookup per group: fine at MVP scale (M6 allows one
    /// group per Premium member); worth a single join query if groups
    /// number in the thousands.
    func groupsNeedingAnOwner() async throws -> [Group] {
        let groups = try await Group.query(on: db).with(\.$owner).sort(\.$name).all()
        var result: [Group] = []
        for group in groups {
            let subscription = try await PlanLimitsService(db: db).subscription(for: group.$owner.id)
            if group.owner.erasedAt != nil || !subscription.isActivePremium {
                result.append(group)
            }
        }
        return result
    }

    func suspendedCount() async throws -> Int {
        try await User.query(on: db).filter(\.$isSuspended == true).filter(\.$erasedAt == nil).count()
    }

    private func activePremium() -> QueryBuilder<Subscription> {
        Subscription.query(on: db)
            .join(User.self, on: \Subscription.$user.$id == \User.$id)
            .filter(User.self, \.$erasedAt == nil)
            .filter(\.$plan == .premium)
            .filter(\.$status == .active)
    }

    // MARK: - Users (criterion #2)

    struct UserRow {
        let user: User
        let subscription: Subscription?
        let hostedEventCount: Int
        let hasPendingDeletion: Bool
    }

    /// The Users table's filter buttons.
    enum UserFilter: String, CaseIterable, Sendable {
        case all, premium, comped, suspended, admins, erased

        var label: String {
            switch self {
            case .all: return "All"
            case .premium: return "Premium"
            case .comped: return "Comped"
            case .suspended: return "Suspended"
            case .admins: return "Admins"
            case .erased: return "Erased"
            }
        }
    }

    private func userQuery(_ query: String, filter: UserFilter) -> QueryBuilder<User> {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let builder = User.query(on: db)
        if !term.isEmpty {
            let pattern = Self.likePattern(term)
            builder.group(.or) { group in
                group.filter(\.$displayName, .custom("ILIKE"), pattern)
                    .filter(\.$email, .custom("ILIKE"), pattern)
            }
        }
        switch filter {
        case .all:
            // Live accounts only, matching the dashboard's count; erased
            // tombstones have their own filter.
            builder.filter(\.$erasedAt == nil)
        case .erased:
            builder.filter(\.$erasedAt != nil)
        case .premium, .comped:
            builder.join(Subscription.self, on: \User.$id == \Subscription.$user.$id)
                .filter(Subscription.self, \.$plan == .premium)
                .filter(Subscription.self, \.$status == .active)
                .filter(\.$erasedAt == nil)
            if filter == .comped {
                builder.filter(Subscription.self, \.$grantedByAdmin == true)
            }
        case .suspended:
            builder.filter(\.$isSuspended == true).filter(\.$erasedAt == nil)
        case .admins:
            builder.filter(\.$role == .admin).filter(\.$erasedAt == nil)
        }
        return builder
    }

    /// How many accounts each filter button would show (ignoring search).
    func userFilterCounts() async throws -> [UserFilter: Int] {
        var counts: [UserFilter: Int] = [:]
        for filter in UserFilter.allCases {
            counts[filter] = try await userQuery("", filter: filter).count()
        }
        return counts
    }

    /// Newest first, matching the search text anywhere in the display
    /// name or email, case-insensitively, within a filter. Returns the
    /// page's rows and the total number of matches.
    func searchUsers(_ query: String, filter: UserFilter = .all, page requested: Int) async throws -> (rows: [UserRow], total: Int, page: Int) {
        let total = try await userQuery(query, filter: filter).count()
        let page = Self.existingPage(requested, total: total, pageSize: Self.pageSize)
        let offset = (page - 1) * Self.pageSize
        let users = try await userQuery(query, filter: filter)
            .sort(\.$createdAt, .descending)
            .sort(\.$id)
            .range(offset..<(offset + Self.pageSize))
            .all()
        let subscriptions = try await subscriptionsByUser(users)
        let ids = try users.map { try $0.requireID() }
        let pending = ids.isEmpty ? [] : try await DeletionRequest.query(on: db)
            .filter(\.$user.$id ~~ ids)
            .filter(\.$processedAt == nil)
            .all()
            .map { $0.$user.id }
        let pendingIDs = Set(pending)
        var rows: [UserRow] = []
        for user in users {
            let id = try user.requireID()
            let hosted = try await Event.query(on: db).filter(\.$hostUser.$id == id).count()
            rows.append(UserRow(user: user, subscription: subscriptions[id], hostedEventCount: hosted,
                                hasPendingDeletion: pendingIDs.contains(id)))
        }
        return (rows, total, page)
    }

    private func subscriptionsByUser(_ users: [User]) async throws -> [UUID: Subscription] {
        let ids = try users.map { try $0.requireID() }
        guard !ids.isEmpty else { return [:] }
        let subs = try await Subscription.query(on: db).filter(\.$user.$id ~~ ids).all()
        return Dictionary(subs.map { ($0.$user.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    struct UserDetail {
        let user: User
        let subscription: Subscription
        let hostedEvents: [Event]
        let memberships: [GroupMembership]
    }

    func userDetail(_ userID: UUID) async throws -> UserDetail? {
        guard let user = try await User.find(userID, on: db) else { return nil }
        let subscription = try await PlanLimitsService(db: db).subscription(for: userID)
        let events = try await Event.query(on: db)
            .filter(\.$hostUser.$id == userID)
            .sort(\.$date, .descending)
            .all()
        let memberships = try await GroupMembership.query(on: db)
            .filter(\.$user.$id == userID)
            .with(\.$group)
            .sort(\.$joinedAt)
            .all()
        return UserDetail(user: user, subscription: subscription, hostedEvents: events, memberships: memberships)
    }

    /// Comp Premium (`grantedByAdmin`) or return to Free. Refuses to
    /// downgrade a paid Stripe subscription here: that has to be cancelled
    /// in Stripe, or the next webhook would put it back (M8).
    func setPlan(_ plan: PlanTier, for userID: UUID, by adminID: UUID) async throws {
        try await db.transaction { tx in
            let user = try await Self.activeUser(userID, on: tx)
            let subscription = try await PlanLimitsService(db: tx).subscription(for: try user.requireID())
            let from = Self.planName(subscription)
            switch plan {
            case .premium:
                guard !subscription.isActivePremium else {
                    throw APIError(code: "no_change", message: "This account is already on Premium.")
                }
                subscription.plan = .premium
                subscription.status = .active
                subscription.grantedByAdmin = true
            case .free:
                guard subscription.isActivePremium else {
                    throw APIError(code: "no_change", message: "This account is already on the Free plan.")
                }
                guard !Self.paysThroughStripe(subscription) else {
                    throw APIError(code: "paid_subscription", message: "This account pays for Premium. Cancel the subscription in Stripe instead.")
                }
                subscription.plan = .free
                subscription.status = .active
                subscription.grantedByAdmin = false
            }
            try await subscription.save(on: tx)
            try await Self.audit(Action.planChanged, by: adminID, targetType: "user", targetID: userID,
                                 metadata: ["from": from, "to": Self.planName(subscription)], on: tx)
        }
    }

    /// Premium bought through Stripe (not comped). Only that is refused a
    /// downgrade here; a comped account with an old Stripe subscription ID
    /// (lapsed, then comped) can still go back to Free.
    static func paysThroughStripe(_ subscription: Subscription) -> Bool {
        subscription.isActivePremium && !subscription.grantedByAdmin && subscription.stripeSubscriptionID != nil
    }

    /// "free", "premium" (paid) or "premium_comped".
    static func planName(_ subscription: Subscription) -> String {
        guard subscription.isActivePremium else { return "free" }
        return subscription.grantedByAdmin ? "premium_comped" : "premium"
    }

    /// Suspending takes effect on the account's very next request: its web
    /// sessions are deleted (so restoring the account later doesn't bring
    /// them back), the bearer authenticator refuses its API tokens while
    /// it's suspended, an open chat socket is refused on its next message
    /// (`ChatService.send`), and signing in again is refused
    /// (`AuthService.findOrCreateUser`), criterion #3. API tokens can't be
    /// revoked individually (no token version yet), so one issued before a
    /// suspension works again after a restore until it expires.
    func setSuspended(_ suspended: Bool, for userID: UUID, by adminID: UUID) async throws {
        guard userID != adminID else {
            throw APIError(code: "forbidden", message: "You can't suspend your own account.")
        }
        try await db.transaction { tx in
            let user = try await Self.activeUser(userID, on: tx)
            guard user.isSuspended != suspended else {
                throw APIError(code: "no_change", message: suspended ? "This account is already suspended." : "This account isn't suspended.")
            }
            user.isSuspended = suspended
            try await user.save(on: tx)
            if suspended {
                try await tx.deleteWebSessions(for: userID)
            }
            try await Self.audit(suspended ? Action.suspended : Action.unsuspended, by: adminID,
                                 targetType: "user", targetID: userID, on: tx)
        }
    }

    // MARK: - Events

    struct EventRow {
        let event: Event
        let attendeeCount: Int
    }

    /// The Events table's filter buttons.
    enum EventFilter: String, CaseIterable, Sendable {
        case all, upcoming, past, cancelled

        var label: String {
            switch self {
            case .all: return "All"
            case .upcoming: return "Upcoming"
            case .past: return "Past"
            case .cancelled: return "Cancelled"
            }
        }
    }

    private func eventQuery(_ query: String, filter: EventFilter, now: Date) -> QueryBuilder<Event> {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let builder = Event.query(on: db)
        if !term.isEmpty {
            let pattern = Self.likePattern(term)
            builder.group(.or) { group in
                group.filter(\.$title, .custom("ILIKE"), pattern)
                    .filter(\.$cityAddress, .custom("ILIKE"), pattern)
                    .filter(\.$venueAddress, .custom("ILIKE"), pattern)
            }
        }
        switch filter {
        case .all: break
        case .upcoming: builder.filter(\.$date >= now).filter(\.$isCancelled == false)
        case .past: builder.filter(\.$date < now).filter(\.$isCancelled == false)
        case .cancelled: builder.filter(\.$isCancelled == true)
        }
        return builder
    }

    func eventFilterCounts(now: Date = Date()) async throws -> [EventFilter: Int] {
        var counts: [EventFilter: Int] = [:]
        for filter in EventFilter.allCases {
            counts[filter] = try await eventQuery("", filter: filter, now: now).count()
        }
        return counts
    }

    /// Matching title, city or venue text. Upcoming events soonest first;
    /// otherwise latest-dated first.
    func searchEvents(_ query: String, filter: EventFilter = .all, page requested: Int, now: Date = Date()) async throws -> (rows: [EventRow], total: Int, page: Int) {
        let total = try await eventQuery(query, filter: filter, now: now).count()
        let page = Self.existingPage(requested, total: total, pageSize: Self.pageSize)
        let offset = (page - 1) * Self.pageSize
        let events = try await eventQuery(query, filter: filter, now: now)
            .with(\.$hostUser)
            .with(\.$hostGroup)
            .sort(\.$date, filter == .upcoming ? .ascending : .descending)
            .sort(\.$id)
            .range(offset..<(offset + Self.pageSize))
            .all()
        var rows: [EventRow] = []
        for event in events {
            let count = try await EventAttendee.query(on: db).filter(\.$event.$id == event.requireID()).count()
            rows.append(EventRow(event: event, attendeeCount: count))
        }
        return (rows, total, page)
    }

    /// The same soft cancel a host can do (`EventService.cancelEvent`):
    /// the row, its attendees and chat survive.
    func cancelEvent(_ eventID: UUID, by adminID: UUID) async throws -> Event {
        try await db.transaction { tx in
            guard let event = try await Event.find(eventID, on: tx) else {
                throw APIError.notFound
            }
            guard !event.isCancelled else {
                throw APIError(code: "no_change", message: "This event is already cancelled.")
            }
            event.isCancelled = true
            try await event.save(on: tx)
            try await Self.audit(Action.eventCancelled, by: adminID, targetType: "event", targetID: eventID, on: tx)
            return event
        }
    }

    // MARK: - Groups (criterion #4)

    struct GroupRow {
        let group: Group
        let memberCount: Int
        let ownerIsPremium: Bool
    }

    func groups(page requested: Int) async throws -> (rows: [GroupRow], total: Int, page: Int) {
        let total = try await Group.query(on: db).count()
        let page = Self.existingPage(requested, total: total, pageSize: Self.pageSize)
        let offset = (page - 1) * Self.pageSize
        let groups = try await Group.query(on: db)
            .with(\.$owner)
            .sort(\.$name)
            .sort(\.$id)
            .range(offset..<(offset + Self.pageSize))
            .all()
        var rows: [GroupRow] = []
        for group in groups {
            let count = try await GroupMembership.query(on: db).filter(\.$group.$id == group.requireID()).count()
            let ownerSubscription = try await PlanLimitsService(db: db).subscription(for: group.$owner.id)
            rows.append(GroupRow(group: group, memberCount: count, ownerIsPremium: ownerSubscription.isActivePremium))
        }
        return (rows, total, page)
    }

    /// Hands a group to a different Premium user, found by email. The new
    /// owner must be active Premium, not suspended or erased, and not
    /// already own a group (one group per membership, M6). Afterwards the
    /// new owner's membership is `.owner` (created if they weren't a
    /// member) and the old owner's is `.member`; an erased old owner's
    /// tombstone membership is removed instead (M9: groups left owned by
    /// a deleted account are handed on this way).
    func transferOwnership(of groupID: UUID, toEmail rawEmail: String, by adminID: UUID) async throws -> Group {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            throw APIError(code: "invalid_new_owner", message: "Enter the new owner's email address.")
        }
        return try await db.transaction { tx in
            try await tx.lockRow(Group.schema, id: groupID)
            guard let group = try await Group.query(on: tx).filter(\.$id == groupID).with(\.$owner).first() else {
                throw APIError.notFound
            }
            let newOwner = try await Self.uniqueUser(email: email, on: tx)
            // Two transfers to the same person at once would both pass the
            // "owns no other group" check below; locking the new owner's
            // row makes the second wait and then see the first.
            try await tx.lockRow(User.schema, id: try newOwner.requireID())
            let oldOwner = group.owner
            let oldOwnerID = try oldOwner.requireID()
            let newOwnerID = try newOwner.requireID()
            guard newOwnerID != oldOwnerID else {
                throw APIError(code: "no_change", message: "That account already owns this group.")
            }
            guard !newOwner.isSuspended else {
                throw APIError(code: "invalid_new_owner", message: "That account is suspended.")
            }
            guard try await PlanLimitsService(db: tx).subscription(for: newOwnerID).isActivePremium else {
                throw APIError(code: "invalid_new_owner", message: "The new owner needs a Premium plan. Comp them Premium first if needed.")
            }
            let ownedMemberships = try await GroupMembership.query(on: tx)
                .filter(\.$user.$id == newOwnerID)
                .filter(\.$role == .owner)
                .count()
            let ownedGroups = try await Group.query(on: tx).filter(\.$owner.$id == newOwnerID).count()
            guard ownedMemberships == 0, ownedGroups == 0 else {
                throw APIError(code: "invalid_new_owner", message: "That account already owns a group (one group per membership).")
            }

            if let membership = try await GroupMembership.query(on: tx)
                .filter(\.$group.$id == groupID)
                .filter(\.$user.$id == newOwnerID)
                .first()
            {
                membership.role = .owner
                try await membership.save(on: tx)
            } else {
                try await GroupMembership(groupID: groupID, userID: newOwnerID, role: .owner).save(on: tx)
            }

            let oldMembership = GroupMembership.query(on: tx)
                .filter(\.$group.$id == groupID)
                .filter(\.$user.$id == oldOwnerID)
            if oldOwner.erasedAt != nil {
                try await oldMembership.delete()
            } else {
                try await oldMembership.set(\.$role, to: .member).update()
            }

            group.$owner.id = newOwnerID
            try await group.save(on: tx)
            try await Self.audit(Action.ownershipTransferred, by: adminID, targetType: "group", targetID: groupID,
                                 metadata: ["fromUserID": oldOwnerID.uuidString, "toUserID": newOwnerID.uuidString], on: tx)
            return group
        }
    }

    // MARK: - Billing (placeholder until M8)

    func compedUsers() async throws -> [User] {
        let subs = try await activePremium()
            .filter(\.$grantedByAdmin == true)
            .with(\.$user)
            .all()
        return subs.map(\.user).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Data requests (criterion #5)

    func pendingDeletions() async throws -> [DeletionRequest] {
        try await DeletionRequest.query(on: db)
            .filter(\.$processedAt == nil)
            .with(\.$user)
            .sort(\.$requestedAt)
            .all()
    }

    func pendingExports() async throws -> [DataExportRequest] {
        try await DataExportRequest.query(on: db)
            .filter(\.$status == .pending)
            .with(\.$user)
            .sort(\.$requestedAt)
            .all()
    }

    /// Erases the account now, the same way `process-deletions` does
    /// (`AccountService.process`), inside the same transaction as its
    /// audit row. The audit row's target is the erased user's ID only.
    func processDeletion(_ requestID: UUID, by adminID: UUID, now: Date = Date()) async throws {
        try await db.transaction { tx in
            guard let request = try await DeletionRequest.find(requestID, on: tx) else {
                throw APIError.notFound
            }
            // `process` locks the request and re-checks it, so a second
            // click, or `process-deletions` running at the same moment,
            // finds it done and nothing is erased or logged twice.
            guard try await AccountService(db: tx).process(request, now: now) else {
                throw APIError(code: "no_change", message: "This request has already been processed.")
            }
            try await Self.audit(Action.deletionProcessed, by: adminID, targetType: "user", targetID: request.$user.id,
                                 metadata: ["requestID": requestID.uuidString], on: tx)
        }
    }

    /// Exports are instant since M9 (created `.ready`), so pending ones
    /// only exist if that ever changes or a row was left behind; this
    /// marks one done.
    func markExportProcessed(_ requestID: UUID, by adminID: UUID) async throws {
        try await db.transaction { tx in
            try await tx.lockRow(DataExportRequest.schema, id: requestID)
            guard let request = try await DataExportRequest.find(requestID, on: tx) else {
                throw APIError.notFound
            }
            guard request.status == .pending else {
                throw APIError(code: "no_change", message: "This request has already been processed.")
            }
            request.status = .ready
            try await request.save(on: tx)
            try await Self.audit(Action.exportProcessed, by: adminID, targetType: "user", targetID: request.$user.id,
                                 metadata: ["requestID": requestID.uuidString], on: tx)
        }
    }

    // MARK: - Audit log

    func auditLog(page requested: Int) async throws -> (rows: [AdminAuditLog], total: Int, page: Int) {
        let total = try await AdminAuditLog.query(on: db).count()
        let page = Self.existingPage(requested, total: total, pageSize: Self.auditPageSize)
        let offset = (page - 1) * Self.auditPageSize
        let rows = try await AdminAuditLog.query(on: db)
            .with(\.$adminUser)
            .sort(\.$createdAt, .descending)
            .sort(\.$id)
            .range(offset..<(offset + Self.auditPageSize))
            .all()
        return (rows, total, page)
    }

    /// The most recent admin actions on one account, for its page.
    func history(ofUser userID: UUID, limit: Int = 10) async throws -> [AdminAuditLog] {
        try await AdminAuditLog.query(on: db)
            .filter(\.$targetType == "user")
            .filter(\.$targetID == userID)
            .with(\.$adminUser)
            .sort(\.$createdAt, .descending)
            .sort(\.$id)
            .range(..<limit)
            .all()
    }

    // MARK: - Helpers

    /// The one live account using this email, matched case-insensitively.
    /// Sign-in matches emails exactly, so two accounts differing only in
    /// case can exist; then this refuses rather than picking one.
    static func uniqueUser(email: String, on db: Database) async throws -> User {
        let matches = try await User.query(on: db)
            .filter(\.$email, .custom("ILIKE"), escapeLike(email))
            .filter(\.$erasedAt == nil)
            .range(..<2)
            .all()
        guard let user = matches.first else {
            throw APIError(code: "invalid_new_owner", message: "No account uses that email address.")
        }
        guard matches.count == 1 else {
            throw APIError(code: "ambiguous_email", message: "More than one account uses that email address in different letter cases. Find the right one in Users.")
        }
        return user
    }

    private static func activeUser(_ userID: UUID, on db: Database) async throws -> User {
        guard let user = try await User.find(userID, on: db), user.erasedAt == nil else {
            throw APIError.notFound
        }
        return user
    }

    private static func audit(
        _ action: String,
        by adminID: UUID,
        targetType: String,
        targetID: UUID,
        metadata: [String: String] = [:],
        on db: Database
    ) async throws {
        try await AdminAuditLog(adminUserID: adminID, action: action, targetType: targetType, targetID: targetID, metadata: metadata)
            .save(on: db)
    }
}
