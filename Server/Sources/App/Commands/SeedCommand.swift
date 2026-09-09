import Fluent
import Vapor
import ExpatEventsAPI

/// `swift run App seed` (or `vapor run seed`). M1 acceptance criterion #3:
/// creates at least 3 users, 2 events (one user-hosted, one group-hosted),
/// and 1 group with a moderator; running it twice doesn't duplicate rows.
///
/// Idempotency strategy: every seeded row is looked up by a fixed, known
/// identifier (email for users, slug for the group) before being created,
/// so re-running finds and reuses existing rows instead of inserting more.
struct SeedCommand: Command {
    struct Signature: CommandSignature {}

    var help: String { "Seeds the database with development sample data." }

    // `Command.run` is synchronous, but every seed helper below is async
    // (they all await Fluent queries) — bridge with `makeFutureWithTask`
    // and block this (command-line, not request-handling) thread until it
    // finishes.
    func run(using context: CommandContext, signature: Signature) throws {
        try context.application.eventLoopGroup.any().makeFutureWithTask {
            try await runAsync(application: context.application, console: context.console)
        }.wait()
    }

    private func runAsync(application: Application, console: Console) async throws {
        let db = application.db

        let alice = try await findOrCreateUser(
            db: db,
            email: "alice@example.com",
            displayName: "Alice Nakamura",
            photoURL: "https://randomuser.me/api/portraits/women/65.jpg"
        )
        let bob = try await findOrCreateUser(
            db: db,
            email: "bob@example.com",
            displayName: "Bob Alavi",
            photoURL: "https://randomuser.me/api/portraits/men/20.jpg"
        )
        let carol = try await findOrCreateUser(
            db: db,
            email: "carol@example.com",
            displayName: "Carol Odinaka",
            photoURL: "https://randomuser.me/api/portraits/women/33.jpg"
        )

        // Alice is Premium so she can own a group (M6); Bob and Carol stay Free.
        try await setPlan(db: db, userID: alice.requireID(), plan: .premium)
        try await setPlan(db: db, userID: bob.requireID(), plan: .free)
        try await setPlan(db: db, userID: carol.requireID(), plan: .free)

        let group = try await findOrCreateGroup(
            db: db,
            slug: "digital-nomads-berlin",
            name: "Digital Nomads Berlin",
            description: "Expats and remote workers meeting up around Berlin.",
            ownerID: alice.requireID()
        )
        try await findOrCreateMembership(db: db, groupID: group.requireID(), userID: alice.requireID(), role: .owner)
        try await findOrCreateMembership(db: db, groupID: group.requireID(), userID: bob.requireID(), role: .moderator)
        try await findOrCreateMembership(db: db, groupID: group.requireID(), userID: carol.requireID(), role: .member)

        _ = try await findOrCreateEvent(
            db: db,
            title: "Trip to the Empire State Building",
            description: "A classic tourist trip, expat-style — meet at the entrance.",
            category: .culture,
            date: Date().addingTimeInterval(60 * 60 * 24 * 7),
            cityAddress: "New York, USA",
            cityLat: 40.7484405, cityLng: -73.9856644,
            venueAddress: "Empire State Building, 5th Avenue, New York, NY, USA",
            venueLat: 40.7484405, venueLng: -73.9856644,
            hostUserID: alice.requireID(),
            hostGroupID: nil
        )

        _ = try await findOrCreateEvent(
            db: db,
            title: "Berlin Nomads Happy Hour",
            description: "Monthly meetup for the group — first round's on us.",
            category: .drinks,
            date: Date().addingTimeInterval(60 * 60 * 24 * 14),
            cityAddress: "Berlin, Germany",
            cityLat: 52.5200066, cityLng: 13.4049540,
            venueAddress: "Prater Garten, Kastanienallee 7-9, Berlin, Germany",
            venueLat: 52.5396, venueLng: 13.4079,
            hostUserID: nil,
            hostGroupID: group.requireID()
        )

        console.print("Seed complete: 3 users, 1 group (owner + moderator + member), 2 events.")
    }

    private func findOrCreateUser(db: Database, email: String, displayName: String, photoURL: String?) async throws -> User {
        if let existing = try await User.query(on: db).filter(\.$email == email).first() {
            return existing
        }
        let user = User(
            displayName: displayName,
            email: email,
            photoURL: photoURL,
            privacyPolicyVersion: LegalVersions.privacyPolicy,
            termsVersion: LegalVersions.terms,
            consentedAt: Date()
        )
        try await user.save(on: db)
        let subscription = Subscription(userID: try user.requireID(), plan: .free, status: .active)
        try await subscription.save(on: db)
        return user
    }

    private func setPlan(db: Database, userID: UUID, plan: PlanTier) async throws {
        guard let sub = try await Subscription.query(on: db).filter(\.$user.$id == userID).first() else { return }
        sub.plan = plan
        try await sub.save(on: db)
    }

    private func findOrCreateGroup(
        db: Database, slug: String, name: String, description: String, ownerID: UUID
    ) async throws -> Group {
        if let existing = try await Group.query(on: db).filter(\.$slug == slug).first() {
            return existing
        }
        let group = Group(name: name, slug: slug, description: description, ownerID: ownerID)
        try await group.save(on: db)
        return group
    }

    private func findOrCreateMembership(db: Database, groupID: UUID, userID: UUID, role: GroupRole) async throws {
        if try await GroupMembership.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .first() != nil
        {
            return
        }
        let membership = GroupMembership(groupID: groupID, userID: userID, role: role)
        try await membership.save(on: db)
    }

    private func findOrCreateEvent(
        db: Database,
        title: String,
        description: String,
        category: EventCategory,
        date: Date,
        cityAddress: String, cityLat: Double, cityLng: Double,
        venueAddress: String, venueLat: Double, venueLng: Double,
        hostUserID: UUID?,
        hostGroupID: UUID?
    ) async throws -> Event {
        if let existing = try await Event.query(on: db).filter(\.$title == title).first() {
            return existing
        }
        let event = Event(
            title: title,
            description: description,
            category: category,
            date: date,
            cityAddress: cityAddress, cityLat: cityLat, cityLng: cityLng,
            venueAddress: venueAddress, venueLat: venueLat, venueLng: venueLng,
            hostUserID: hostUserID,
            hostGroupID: hostGroupID
        )
        try await event.save(on: db)
        return event
    }
}
