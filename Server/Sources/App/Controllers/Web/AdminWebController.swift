import Fluent
import Vapor
import ExpatEventsAPI

/// The admin site, `/admin` (M10, architecture §12): Dashboard, Users,
/// Events, Groups, Billing (a placeholder until M8), Data requests and
/// the Audit log. The JSON `/api/v1/admin` surface is deferred to M11
/// (user's M10 decision); both would share `AdminService`.
///
/// Access (criterion #1): a signed-out visitor is redirected to `/login`,
/// a signed-in non-admin gets a 403 from `AdminMiddleware`, and neither
/// reaches a handler. The session cookie is SameSite=Lax (Vapor's
/// default), so another site can't post these forms with an admin's
/// session.
///
/// Look (user's M10 theme decision, after the first checkpoint): its own
/// layout (`admin/layout.leaf`) with a dark left sidebar, Tailwind
/// utility classes, dashboard charts drawn as inline SVG from
/// `AdminCharts`, and tables with filter buttons, zebra rows and icon
/// action buttons. Every badge/pill colour is a Tailwind class string
/// chosen here, so templates never compare values.
///
/// Every action form posts over htmx. Success answers with `HX-Redirect`
/// back to the page it came from with a fixed notice (a plain 303 without
/// htmx); a rejection swaps a message into the page's `#admin-alert` box
/// (a plain error page without htmx). Destructive actions carry
/// `hx-confirm`, shown as the layout's own dialog.
struct AdminWebController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped(
            User.activeSessionAuthenticator(),
            HTMXAwareSignInRedirect(),
            NotSuspendedMiddleware(),
            AdminMiddleware()
        ).grouped("admin")

        admin.get(use: dashboard)
        admin.get("activity", use: activityChart)
        admin.get("users", use: users)
        admin.get("users", "table", use: usersTable)
        admin.get("users", ":userID", use: userDetail)
        admin.post("users", ":userID", "plan", use: setPlan)
        admin.post("users", ":userID", "suspend", use: suspend)
        admin.post("users", ":userID", "unsuspend", use: unsuspend)
        admin.get("events", use: events)
        admin.post("events", ":eventID", "cancel", use: cancelEvent)
        admin.get("groups", use: groups)
        admin.post("groups", ":groupID", "transfer-owner", use: transferOwner)
        admin.get("billing", use: billing)
        admin.get("data-requests", use: dataRequests)
        admin.post("data-requests", "deletions", ":requestID", "process", use: processDeletion)
        admin.post("data-requests", "exports", ":requestID", "process", use: processExport)
        admin.get("audit-log", use: auditLog)
    }

    // MARK: - Layout context

    enum Section {
        case dashboard, users, events, groups, billing, dataRequests, auditLog
    }

    /// Which sidebar item is current, as plain Bools for the layout.
    struct Nav: Encodable {
        let dashboard: Bool
        let users: Bool
        let events: Bool
        let groups: Bool
        let billing: Bool
        let dataRequests: Bool
        let auditLog: Bool

        init(_ section: Section) {
            dashboard = section == .dashboard
            users = section == .users
            events = section == .events
            groups = section == .groups
            billing = section == .billing
            dataRequests = section == .dataRequests
            auditLog = section == .auditLog
        }
    }

    /// What `admin/layout.leaf` needs on every page: the sidebar state,
    /// who's signed in, the pending-deletions badge and any notice.
    struct Chrome: Encodable {
        let nav: Nav
        let section: String
        let adminName: String
        let adminInitials: String
        let pendingDeletions: Int
        let hasPendingDeletions: Bool
        let notice: String?
    }

    static func chrome(_ req: Request, _ section: Section, sectionLabel: String) async throws -> Chrome {
        let admin = try req.auth.require(User.self)
        let pending = try await DeletionRequest.query(on: req.db).filter(\.$processedAt == nil).count()
        return Chrome(
            nav: Nav(section),
            section: sectionLabel,
            adminName: admin.displayName,
            adminInitials: initials(admin.displayName),
            pendingDeletions: pending,
            hasPendingDeletions: pending > 0,
            notice: notice(req)
        )
    }

    /// Fixed success messages, keyed by the `notice` query parameter, so
    /// a crafted link can't put arbitrary text on an admin page.
    static let notices: [String: String] = [
        "plan": "Plan updated.",
        "suspended": "Account suspended and signed out of the website. It can't sign in or use the API until restored.",
        "unsuspended": "Account restored.",
        "cancelled": "Event cancelled.",
        "transferred": "Ownership transferred.",
        "deletion-processed": "Account erased.",
        "export-processed": "Export request marked processed.",
    ]

    static func notice(_ req: Request) -> String? {
        (try? req.query.get(String.self, at: "notice")).flatMap { notices[$0] }
    }

    // MARK: - Shared pieces

    struct Pill: Encodable {
        let label: String
        let classes: String
    }

    enum Tone {
        case neutral, gold, teal, red, green, violet, slate

        var classes: String {
            switch self {
            case .neutral: return "bg-slate-100 text-slate-600 ring-slate-500/20"
            case .gold: return "bg-amber-50 text-amber-700 ring-amber-600/25"
            case .teal: return "bg-teal-50 text-teal-700 ring-teal-600/25"
            case .red: return "bg-rose-50 text-rose-700 ring-rose-600/25"
            case .green: return "bg-emerald-50 text-emerald-700 ring-emerald-600/25"
            case .violet: return "bg-violet-50 text-violet-700 ring-violet-600/25"
            case .slate: return "bg-slate-200 text-slate-700 ring-slate-500/25"
            }
        }
    }

    static func pill(_ label: String, _ tone: Tone) -> Pill {
        Pill(label: label, classes: tone.classes)
    }

    static let avatarColors = [
        "bg-sky-600", "bg-violet-600", "bg-amber-500", "bg-emerald-600",
        "bg-rose-500", "bg-indigo-600", "bg-teal-600", "bg-fuchsia-600",
    ]

    /// A stable colour per ID, so an account keeps its avatar colour.
    static func avatarColor(_ id: UUID) -> String {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 + Int($1) }
        return avatarColors[sum % avatarColors.count]
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    struct Chip: Encodable {
        let label: String
        let count: String
        let url: String
        let fragmentURL: String
        let isActive: Bool
    }

    struct Pager: Encodable {
        let showing: String
        let previousURL: String?
        let nextURL: String?
        let pageLabel: String
        let hasPages: Bool

        init(path: String, items: [(String, String)], page: Int, total: Int, pageSize: Int) {
            let pageCount = max(1, (total + pageSize - 1) / pageSize)
            let first = total == 0 ? 0 : (page - 1) * pageSize + 1
            let last = min(page * pageSize, total)
            showing = total == 0 ? "No results" : "Showing \(first)–\(last) of \(AdminCharts.number(total))"
            previousURL = page > 1 ? PlacesWebController.url(path, items + [("page", String(page - 1))]) : nil
            nextURL = page < pageCount ? PlacesWebController.url(path, items + [("page", String(page + 1))]) : nil
            pageLabel = "Page \(min(page, pageCount)) of \(pageCount)"
            hasPages = pageCount > 1
        }
    }

    struct AlertContext: Encodable {
        let message: String
    }

    struct ErrorPageContext: Encodable {
        let title = "Admin"
        let chrome: Chrome
        let message: String
        let backURL: String
    }

    static func query(_ req: Request) -> String {
        String(((try? req.query.get(String.self, at: "q")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    }

    static func page(_ req: Request) -> Int {
        AdminService.clampedPage(try? req.query.get(Int.self, at: "page"))
    }

    // MARK: - Dashboard

    struct Kpi: Encodable {
        let value: String
        let delta: String
        let deltaUp: Bool
        let deltaDown: Bool
        let caption: String
        let sparkline: String?
    }

    struct AttentionItem: Encodable {
        let title: String
        let detail: String
        let url: String
        let actionLabel: String
        let isUrgent: Bool
    }

    struct ActivityContext: Encodable {
        let activity: AdminCharts.Activity
    }

    struct DashboardContext: Encodable {
        let title = "Admin · Dashboard"
        let chrome: Chrome
        let accounts: Kpi
        let premium: Kpi
        let events: Kpi
        let users: String
        let premiumCount: String
        let activity: AdminCharts.Activity
        let free: String
        let paid: String
        let comped: String
        let premiumShare: String
        let donut: [AdminCharts.DonutSegment]
        let categories: [AdminCharts.CategoryBar]
        let categoriesHeight: Int
        let hasCategories: Bool
        let groupsNeedingOwner: Int
        let suspended: Int
        let pendingDeletions: Int
        let attention: [AttentionItem]
        let hasAttention: Bool
    }

    @Sendable
    func dashboard(req: Request) async throws -> View {
        let service = AdminService(db: req.db)
        let now = Date()
        let stats = try await service.stats(now: now)
        let headline = try await service.headline(now: now)
        let weekly = try await service.activity(.twelveWeeks, now: now)
        let range = Self.activityRange(req)
        let buckets = range == .twelveWeeks ? weekly : try await service.activity(range, now: now)
        let categories = AdminCharts.categories(try await service.upcomingEventsByCategory(now: now))
        let suspended = try await service.suspendedCount()

        let paid = stats.premium - stats.comped
        let free = max(stats.users - stats.premium, 0)
        let share = stats.users == 0 ? 0 : Double(stats.premium) / Double(stats.users) * 100

        var attention: [AttentionItem] = []
        for request in try await service.pendingDeletions().prefix(5) {
            let deadline = Self.deadline(for: request, now: now)
            attention.append(AttentionItem(
                title: "Deletion request · \(request.user.displayName)",
                detail: "Due \(deadline.dueOn) · \(deadline.label)",
                url: "/admin/data-requests", actionLabel: "Review", isUrgent: true
            ))
        }
        let needOwner = try await service.groupsNeedingAnOwner()
        for group in needOwner.prefix(5) {
            attention.append(AttentionItem(
                title: "Group needs a Premium owner · \(group.name)",
                detail: group.owner.erasedAt != nil ? "The owner's account was erased" : "The owner isn't on Premium any more",
                url: "/admin/groups", actionLabel: "Open", isUrgent: false
            ))
        }

        return try await req.view.render("admin/dashboard", DashboardContext(
            chrome: try await Self.chrome(req, .dashboard, sectionLabel: "Overview"),
            accounts: Kpi(
                value: AdminCharts.number(stats.users),
                delta: Self.delta(headline.newAccounts30, against: headline.newAccountsPrevious30, unit: "new"),
                deltaUp: headline.newAccounts30 > headline.newAccountsPrevious30,
                deltaDown: headline.newAccounts30 < headline.newAccountsPrevious30,
                caption: "\(AdminCharts.number(headline.newAccounts30)) joined in the last 30 days",
                sparkline: AdminCharts.sparkline(weekly.map { $0.newAccounts })
            ),
            premium: Kpi(
                value: AdminCharts.number(stats.premium),
                delta: "",
                deltaUp: false,
                deltaDown: false,
                caption: "\(AdminCharts.number(paid)) paid · \(AdminCharts.number(stats.comped)) comped",
                sparkline: nil
            ),
            events: Kpi(
                value: AdminCharts.number(stats.eventsThisWeek),
                delta: Self.delta(headline.eventsNext7, against: headline.eventsLast7, unit: ""),
                deltaUp: headline.eventsNext7 > headline.eventsLast7,
                deltaDown: headline.eventsNext7 < headline.eventsLast7,
                caption: "vs \(headline.eventsLast7) in the past 7 days",
                sparkline: AdminCharts.sparkline(weekly.map { $0.eventsCreated })
            ),
            users: AdminCharts.number(stats.users),
            premiumCount: AdminCharts.number(stats.premium),
            activity: AdminCharts.activity(buckets, range: range),
            free: AdminCharts.number(free),
            paid: AdminCharts.number(paid),
            comped: AdminCharts.number(stats.comped),
            premiumShare: String(format: "%.1f%%", share),
            donut: AdminCharts.donut([(free, "text-teal-600"), (paid, "text-amber-500"), (stats.comped, "text-violet-500")]),
            categories: categories.bars,
            categoriesHeight: categories.height,
            hasCategories: !categories.bars.isEmpty,
            groupsNeedingOwner: needOwner.count,
            suspended: suspended,
            pendingDeletions: stats.pendingDeletions,
            attention: attention,
            hasAttention: !attention.isEmpty
        ))
    }

    /// The range buttons on the activity chart swap just the chart.
    @Sendable
    func activityChart(req: Request) async throws -> View {
        let range = Self.activityRange(req)
        let buckets = try await AdminService(db: req.db).activity(range)
        return try await req.view.render("admin/activity-chart", ActivityContext(activity: AdminCharts.activity(buckets, range: range)))
    }

    static func activityRange(_ req: Request) -> AdminService.ActivityRange {
        (try? req.query.get(String.self, at: "range")).flatMap(AdminService.ActivityRange.init(rawValue:)) ?? .twelveWeeks
    }

    /// "▲ 4 new", "▼ 2", or "No change".
    static func delta(_ current: Int, against previous: Int, unit: String) -> String {
        let difference = current - previous
        guard difference != 0 else { return "No change" }
        let suffix = unit.isEmpty ? "" : " \(unit)"
        return difference > 0 ? "▲ \(difference)\(suffix)" : "▼ \(-difference)\(suffix)"
    }

    // MARK: - Users

    struct UserRowContext: Encodable {
        let detailURL: String
        let displayName: String
        let email: String
        let initials: String
        let avatarColor: String
        let plan: Pill
        let statuses: [Pill]
        let hostedEvents: Int
        let joinedOn: String
        let planURL: String
        let suspendURL: String
        let unsuspendURL: String
        let canComp: Bool
        let canRevertToFree: Bool
        let canSuspend: Bool
        let canUnsuspend: Bool
    }

    /// The results' keys sit at the top level of the page context too, so
    /// `admin/users-results.leaf` reads the same keys when `#extend`ed into
    /// the page as when rendered alone for the search box and filters.
    struct UsersResultsContext: Encodable {
        let filter: String
        let chips: [Chip]
        let users: [UserRowContext]
        let isEmpty: Bool
        let pager: Pager
        let returnURL: String
    }

    struct UsersPageContext: Encodable {
        let title = "Admin · Users"
        let chrome: Chrome
        let query: String
        let filter: String
        let chips: [Chip]
        let users: [UserRowContext]
        let isEmpty: Bool
        let pager: Pager
        let returnURL: String
    }

    @Sendable
    func users(req: Request) async throws -> View {
        let (query, results) = try await usersResults(req)
        return try await req.view.render("admin/users", UsersPageContext(
            chrome: try await Self.chrome(req, .users, sectionLabel: "Manage"),
            query: query, filter: results.filter, chips: results.chips, users: results.users,
            isEmpty: results.isEmpty, pager: results.pager, returnURL: results.returnURL
        ))
    }

    /// The search box's and filter buttons' htmx target: the filters and
    /// the table, not the whole page.
    @Sendable
    func usersTable(req: Request) async throws -> View {
        let (_, results) = try await usersResults(req)
        return try await req.view.render("admin/users-results", results)
    }

    private func usersResults(_ req: Request) async throws -> (String, UsersResultsContext) {
        let admin = try req.auth.require(User.self)
        let adminID = try admin.requireID()
        let query = Self.query(req)
        let filter = (try? req.query.get(String.self, at: "filter")).flatMap(AdminService.UserFilter.init(rawValue:)) ?? .all
        let service = AdminService(db: req.db)
        let (rows, total, page) = try await service.searchUsers(query, filter: filter, page: Self.page(req))
        let counts = try await service.userFilterCounts()

        let users = try rows.map { row -> UserRowContext in
            let user = row.user
            let id = try user.requireID()
            let isErased = user.erasedAt != nil
            let isPremium = row.subscription?.isActivePremium ?? false
            let paysThroughStripe = row.subscription.map(AdminService.paysThroughStripe) ?? false
            return UserRowContext(
                detailURL: "/admin/users/\(id.uuidString)",
                displayName: user.displayName,
                email: isErased ? "" : user.email,
                initials: Self.initials(user.displayName),
                avatarColor: isErased ? "bg-slate-400" : Self.avatarColor(id),
                plan: Self.planPill(row.subscription),
                statuses: Self.statusPills(user, hasPendingDeletion: row.hasPendingDeletion),
                hostedEvents: row.hostedEventCount,
                joinedOn: user.createdAt.map(Self.formatDay) ?? "",
                planURL: "/admin/users/\(id.uuidString)/plan",
                suspendURL: "/admin/users/\(id.uuidString)/suspend",
                unsuspendURL: "/admin/users/\(id.uuidString)/unsuspend",
                canComp: !isErased && !isPremium,
                canRevertToFree: !isErased && isPremium && !paysThroughStripe,
                canSuspend: !isErased && id != adminID && !user.isSuspended,
                canUnsuspend: !isErased && user.isSuspended
            )
        }
        let searchItems: [(String, String)] = query.isEmpty ? [] : [("q", query)]
        let chips = AdminService.UserFilter.allCases.map { option -> Chip in
            let items = searchItems + (option == .all ? [] : [("filter", option.rawValue)])
            return Chip(
                label: option.label,
                count: AdminCharts.number(counts[option] ?? 0),
                url: items.isEmpty ? "/admin/users" : PlacesWebController.url("/admin/users", items),
                fragmentURL: items.isEmpty ? "/admin/users/table" : PlacesWebController.url("/admin/users/table", items),
                isActive: option == filter
            )
        }
        let listItems = searchItems + (filter == .all ? [] : [("filter", filter.rawValue)])
        return (query, UsersResultsContext(
            filter: filter.rawValue,
            chips: chips,
            users: users,
            isEmpty: users.isEmpty,
            pager: Pager(path: "/admin/users", items: listItems, page: page, total: total, pageSize: AdminService.pageSize),
            returnURL: PlacesWebController.url("/admin/users", listItems + [("page", String(page))])
        ))
    }

    static func planPill(_ subscription: Subscription?) -> Pill {
        guard let subscription else { return pill("Free", .neutral) }
        switch AdminService.planName(subscription) {
        case "premium_comped": return pill("Premium · comped", .teal)
        case "premium": return pill("Premium", .gold)
        default: return pill("Free", .neutral)
        }
    }

    static func statusPills(_ user: User, hasPendingDeletion: Bool) -> [Pill] {
        if user.erasedAt != nil { return [pill("Erased", .slate)] }
        var pills: [Pill] = []
        if user.role == .admin { pills.append(pill("Admin", .violet)) }
        if user.isSuspended { pills.append(pill("Suspended", .red)) }
        if hasPendingDeletion { pills.append(pill("Deletion requested", .red)) }
        if !user.isSuspended && !hasPendingDeletion { pills.append(pill("Active", .green)) }
        return pills
    }

    struct HostedEventContext: Encodable {
        let title: String
        let url: String
        let date: Date
        let timeZone: String?
        let status: Pill
        let attendees: Int
    }

    struct MembershipContext: Encodable {
        let name: String
        let url: String
        let role: Pill
    }

    struct HistoryContext: Encodable {
        let when: String
        let adminName: String
        let action: Pill
        let details: String
    }

    struct UserDetailContext: Encodable {
        let title = "Admin · User"
        let chrome: Chrome
        let userID: String
        let displayName: String
        let email: String
        let initials: String
        let avatarColor: String
        let profileURL: String
        let joinedOn: String
        let plan: Pill
        let statuses: [Pill]
        let isSuspended: Bool
        let isErased: Bool
        let isSelf: Bool
        let canComp: Bool
        let canRevertToFree: Bool
        let paysThroughStripe: Bool
        let canSuspend: Bool
        let canUnsuspend: Bool
        let hostedEvents: [HostedEventContext]
        let hostedEventCount: Int
        let hasHostedEvents: Bool
        let groups: [MembershipContext]
        let groupCount: Int
        let hasGroups: Bool
        let history: [HistoryContext]
        let hasHistory: Bool
    }

    @Sendable
    func userDetail(req: Request) async throws -> View {
        let admin = try req.auth.require(User.self)
        let userID = try Self.uuid(req, "userID")
        let service = AdminService(db: req.db)
        guard let detail = try await service.userDetail(userID) else {
            throw Abort(.notFound)
        }
        let user = detail.user
        let isErased = user.erasedAt != nil
        let isSelf = try admin.requireID() == userID
        let subscription = detail.subscription
        let pendingDeletion = try await AccountService(db: req.db).pendingDeletionRequest(for: userID) != nil
        let now = Date()
        var hostedEvents: [HostedEventContext] = []
        for event in detail.hostedEvents {
            let eventID = try event.requireID()
            let attendees = try await EventAttendee.query(on: req.db).filter(\.$event.$id == eventID).count()
            hostedEvents.append(HostedEventContext(
                title: event.title,
                url: "/events/\(eventID.uuidString)",
                date: event.date,
                timeZone: event.timeZone,
                status: Self.eventStatus(event, now: now),
                attendees: attendees
            ))
        }
        let history = try await service.history(ofUser: userID).map(Self.historyRow)
        return try await req.view.render("admin/user-detail", UserDetailContext(
            chrome: try await Self.chrome(req, .users, sectionLabel: "Manage › Users"),
            userID: userID.uuidString,
            displayName: user.displayName,
            email: isErased ? "" : user.email,
            initials: Self.initials(user.displayName),
            avatarColor: isErased ? "bg-slate-400" : Self.avatarColor(userID),
            profileURL: "/profile/\(userID.uuidString)",
            joinedOn: user.createdAt.map(Self.formatDay) ?? "",
            plan: Self.planPill(subscription),
            statuses: Self.statusPills(user, hasPendingDeletion: pendingDeletion),
            isSuspended: user.isSuspended && !isErased,
            isErased: isErased,
            isSelf: isSelf,
            canComp: !isErased && !subscription.isActivePremium,
            canRevertToFree: !isErased && subscription.isActivePremium && !AdminService.paysThroughStripe(subscription),
            paysThroughStripe: AdminService.paysThroughStripe(subscription),
            canSuspend: !isErased && !isSelf && !user.isSuspended,
            canUnsuspend: !isErased && user.isSuspended,
            hostedEvents: hostedEvents,
            hostedEventCount: hostedEvents.count,
            hasHostedEvents: !hostedEvents.isEmpty,
            groups: detail.memberships.map {
                MembershipContext(name: $0.group.name, url: "/groups/\($0.group.slug)", role: Self.rolePill($0.role))
            },
            groupCount: detail.memberships.count,
            hasGroups: !detail.memberships.isEmpty,
            history: history,
            hasHistory: !history.isEmpty
        ))
    }

    static func rolePill(_ role: GroupRole) -> Pill {
        switch role {
        case .owner: return pill("Owner", .gold)
        case .moderator: return pill("Moderator", .teal)
        case .member: return pill("Member", .neutral)
        }
    }

    struct PlanForm: Content {
        let plan: String
    }

    struct ReturnForm: Content {
        let returnTo: String?
    }

    /// Row buttons on the Users table send `returnTo` (the list they're
    /// on); the account page's buttons don't, and go back there.
    private func back(_ req: Request, detail userID: UUID) -> String {
        Self.safeReturn((try? req.content.decode(ReturnForm.self))?.returnTo, fallback: "/admin/users/\(userID.uuidString)")
    }

    @Sendable
    func setPlan(req: Request) async throws -> Response {
        let admin = try req.auth.require(User.self)
        let userID = try Self.uuid(req, "userID")
        let back = self.back(req, detail: userID)
        guard let plan = (try? req.content.decode(PlanForm.self)).flatMap({ PlanTier(rawValue: $0.plan) }) else {
            return try await Self.fail(req, "Choose a plan.", back: back, section: .users)
        }
        return try await Self.perform(req, back: back, section: .users, notice: "plan") {
            try await AdminService(db: req.db).setPlan(plan, for: userID, by: admin.requireID())
        }
    }

    @Sendable
    func suspend(req: Request) async throws -> Response {
        try await setSuspended(true, req: req)
    }

    @Sendable
    func unsuspend(req: Request) async throws -> Response {
        try await setSuspended(false, req: req)
    }

    private func setSuspended(_ suspended: Bool, req: Request) async throws -> Response {
        let admin = try req.auth.require(User.self)
        let userID = try Self.uuid(req, "userID")
        return try await Self.perform(req, back: back(req, detail: userID), section: .users,
                                      notice: suspended ? "suspended" : "unsuspended") {
            try await AdminService(db: req.db).setSuspended(suspended, for: userID, by: admin.requireID())
        }
    }

    // MARK: - Events

    struct EventRowContext: Encodable {
        let cancelURL: String
        let url: String
        let title: String
        let date: Date
        let timeZone: String?
        let hostLabel: String
        let hostURL: String?
        let cityAddress: String
        let attendeeCount: Int
        let status: Pill
        let isPrivate: Bool
        let canCancel: Bool
    }

    struct EventsPageContext: Encodable {
        let title = "Admin · Events"
        let chrome: Chrome
        let query: String
        let filter: String
        let chips: [Chip]
        let events: [EventRowContext]
        let isEmpty: Bool
        let pager: Pager
        /// Where a cancel returns to, so the search, filter and page are kept.
        let returnURL: String
    }

    @Sendable
    func events(req: Request) async throws -> View {
        let query = Self.query(req)
        let filter = (try? req.query.get(String.self, at: "filter")).flatMap(AdminService.EventFilter.init(rawValue:)) ?? .all
        let now = Date()
        let service = AdminService(db: req.db)
        let (rows, total, page) = try await service.searchEvents(query, filter: filter, page: Self.page(req), now: now)
        let counts = try await service.eventFilterCounts(now: now)
        let events = try rows.map { row -> EventRowContext in
            let event = row.event
            let id = try event.requireID().uuidString
            let hostURL: String? = try event.hostUser.map { "/admin/users/\(try $0.requireID().uuidString)" }
            return EventRowContext(
                cancelURL: "/admin/events/\(id)/cancel",
                url: "/events/\(id)",
                title: event.title,
                date: event.date,
                timeZone: event.timeZone,
                hostLabel: event.hostGroup?.name ?? event.hostUser?.displayName ?? "",
                hostURL: event.hostGroup == nil ? hostURL : nil,
                cityAddress: event.cityAddress,
                attendeeCount: row.attendeeCount,
                status: Self.eventStatus(event, now: now),
                isPrivate: event.visibility == .private,
                canCancel: !event.isCancelled
            )
        }
        let searchItems: [(String, String)] = query.isEmpty ? [] : [("q", query)]
        let chips = AdminService.EventFilter.allCases.map { option -> Chip in
            let items = searchItems + (option == .all ? [] : [("filter", option.rawValue)])
            let url = items.isEmpty ? "/admin/events" : PlacesWebController.url("/admin/events", items)
            return Chip(label: option.label, count: AdminCharts.number(counts[option] ?? 0), url: url, fragmentURL: url, isActive: option == filter)
        }
        let listItems = searchItems + (filter == .all ? [] : [("filter", filter.rawValue)])
        return try await req.view.render("admin/events", EventsPageContext(
            chrome: try await Self.chrome(req, .events, sectionLabel: "Manage"),
            query: query,
            filter: filter.rawValue,
            chips: chips,
            events: events,
            isEmpty: events.isEmpty,
            pager: Pager(path: "/admin/events", items: listItems, page: page, total: total, pageSize: AdminService.pageSize),
            returnURL: PlacesWebController.url("/admin/events", listItems + [("page", String(page))])
        ))
    }

    static func eventStatus(_ event: Event, now: Date) -> Pill {
        if event.isCancelled { return pill("Cancelled", .red) }
        return event.date >= now ? pill("Upcoming", .green) : pill("Past", .neutral)
    }

    @Sendable
    func cancelEvent(req: Request) async throws -> Response {
        let admin = try req.auth.require(User.self)
        let eventID = try Self.uuid(req, "eventID")
        let back = Self.safeReturn((try? req.content.decode(ReturnForm.self))?.returnTo, fallback: "/admin/events")
        return try await Self.perform(req, back: back, section: .events, notice: "cancelled") {
            _ = try await AdminService(db: req.db).cancelEvent(eventID, by: admin.requireID())
        }
    }

    // MARK: - Groups

    struct GroupRowContext: Encodable {
        let id: String
        let transferURL: String
        let url: String
        let name: String
        let initials: String
        let avatarColor: String
        let visibility: Pill
        let ownerName: String
        let ownerEmail: String
        let ownerURL: String
        let ownerErased: Bool
        let ownerLapsed: Bool
        let memberCount: Int
        let createdOn: String
    }

    struct GroupsPageContext: Encodable {
        let title = "Admin · Groups"
        let chrome: Chrome
        let groups: [GroupRowContext]
        let isEmpty: Bool
        let pager: Pager
    }

    @Sendable
    func groups(req: Request) async throws -> View {
        let (rows, total, page) = try await AdminService(db: req.db).groups(page: Self.page(req))
        let groups = try rows.map { row -> GroupRowContext in
            let group = row.group
            let owner = group.owner
            let id = try group.requireID()
            let ownerErased = owner.erasedAt != nil
            return GroupRowContext(
                id: id.uuidString,
                transferURL: "/admin/groups/\(id.uuidString)/transfer-owner",
                url: "/groups/\(group.slug)",
                name: group.name,
                initials: Self.initials(group.name),
                avatarColor: Self.avatarColor(id),
                visibility: group.visibility == .inviteOnly ? Self.pill("Invite-only", .violet) : Self.pill("Public", .neutral),
                ownerName: owner.displayName,
                ownerEmail: ownerErased ? "" : owner.email,
                ownerURL: "/admin/users/\(try owner.requireID().uuidString)",
                ownerErased: ownerErased,
                ownerLapsed: !ownerErased && !row.ownerIsPremium,
                memberCount: row.memberCount,
                createdOn: group.createdAt.map(Self.formatDay) ?? ""
            )
        }
        return try await req.view.render("admin/groups", GroupsPageContext(
            chrome: try await Self.chrome(req, .groups, sectionLabel: "Manage"),
            groups: groups,
            isEmpty: groups.isEmpty,
            pager: Pager(path: "/admin/groups", items: [], page: page, total: total, pageSize: AdminService.pageSize)
        ))
    }

    struct TransferForm: Content {
        let newOwnerEmail: String
    }

    @Sendable
    func transferOwner(req: Request) async throws -> Response {
        let admin = try req.auth.require(User.self)
        let groupID = try Self.uuid(req, "groupID")
        let email = (try? req.content.decode(TransferForm.self))?.newOwnerEmail ?? ""
        return try await Self.perform(req, back: "/admin/groups", section: .groups, notice: "transferred") {
            _ = try await AdminService(db: req.db).transferOwnership(of: groupID, toEmail: email, by: admin.requireID())
        }
    }

    // MARK: - Billing (placeholder until M8)

    struct CompedUserContext: Encodable {
        let displayName: String
        let email: String
        let initials: String
        let avatarColor: String
        let detailURL: String
    }

    struct BillingPageContext: Encodable {
        let title = "Admin · Billing"
        let chrome: Chrome
        let free: Int
        let paidPremium: Int
        let comped: Int
        let compedUsers: [CompedUserContext]
        let hasCompedUsers: Bool
    }

    @Sendable
    func billing(req: Request) async throws -> View {
        let service = AdminService(db: req.db)
        let stats = try await service.stats()
        let comped = try await service.compedUsers()
        var compedUsers: [CompedUserContext] = []
        for user in comped {
            let id = try user.requireID()
            compedUsers.append(CompedUserContext(
                displayName: user.displayName, email: user.email, initials: Self.initials(user.displayName),
                avatarColor: Self.avatarColor(id), detailURL: "/admin/users/\(id.uuidString)"
            ))
        }
        return try await req.view.render("admin/billing", BillingPageContext(
            chrome: try await Self.chrome(req, .billing, sectionLabel: "Money & compliance"),
            free: max(stats.users - stats.premium, 0),
            paidPremium: stats.premium - stats.comped,
            comped: stats.comped,
            compedUsers: compedUsers,
            hasCompedUsers: !compedUsers.isEmpty
        ))
    }

    // MARK: - Data requests

    struct Deadline {
        let dueOn: String
        let label: String
        let isOverdue: Bool
        let percentUsed: Int
    }

    static func deadline(for request: DeletionRequest, now: Date) -> Deadline {
        let day: TimeInterval = 24 * 60 * 60
        let requested = request.requestedAt ?? now
        let window = TimeInterval(AdminService.deletionDeadlineDays) * day
        let due = requested.addingTimeInterval(window)
        let daysLeft = Int((due.timeIntervalSince(now) / day).rounded(.down))
        let used = Int((now.timeIntervalSince(requested) / window * 100).rounded())
        return Deadline(
            dueOn: formatDay(due),
            label: daysLeft >= 0 ? "\(daysLeft) day\(daysLeft == 1 ? "" : "s") left" : "Overdue by \(-daysLeft) day\(daysLeft == -1 ? "" : "s")",
            isOverdue: daysLeft < 0,
            percentUsed: min(max(used, 2), 100)
        )
    }

    struct DeletionRowContext: Encodable {
        let processURL: String
        let userURL: String
        let displayName: String
        let email: String
        let initials: String
        let avatarColor: String
        let requestedOn: String
        let dueOn: String
        let deadlineLabel: String
        let isOverdue: Bool
        let progressWidth: String
        let ownsGroup: Bool
    }

    struct ExportRowContext: Encodable {
        let processURL: String
        let userURL: String
        let displayName: String
        let email: String
        let requestedOn: String
    }

    struct DataRequestsPageContext: Encodable {
        let title = "Admin · Data requests"
        let chrome: Chrome
        let deletions: [DeletionRowContext]
        let hasDeletions: Bool
        let exports: [ExportRowContext]
        let hasExports: Bool
    }

    @Sendable
    func dataRequests(req: Request) async throws -> View {
        let service = AdminService(db: req.db)
        let now = Date()
        var deletions: [DeletionRowContext] = []
        for request in try await service.pendingDeletions() {
            let user = request.user
            let userID = try user.requireID()
            let deadline = Self.deadline(for: request, now: now)
            let ownsGroup = try await Group.query(on: req.db).filter(\.$owner.$id == userID).count() > 0
            deletions.append(DeletionRowContext(
                processURL: "/admin/data-requests/deletions/\(try request.requireID().uuidString)/process",
                userURL: "/admin/users/\(userID.uuidString)",
                displayName: user.displayName,
                email: user.email,
                initials: Self.initials(user.displayName),
                avatarColor: Self.avatarColor(userID),
                requestedOn: request.requestedAt.map(Self.formatDay) ?? "",
                dueOn: deadline.dueOn,
                deadlineLabel: deadline.label,
                isOverdue: deadline.isOverdue,
                progressWidth: "\(deadline.percentUsed)%",
                ownsGroup: ownsGroup
            ))
        }
        var exports: [ExportRowContext] = []
        for request in try await service.pendingExports() {
            exports.append(ExportRowContext(
                processURL: "/admin/data-requests/exports/\(try request.requireID().uuidString)/process",
                userURL: "/admin/users/\(try request.user.requireID().uuidString)",
                displayName: request.user.displayName,
                email: request.user.email,
                requestedOn: request.requestedAt.map(Self.formatDay) ?? ""
            ))
        }
        return try await req.view.render("admin/data-requests", DataRequestsPageContext(
            chrome: try await Self.chrome(req, .dataRequests, sectionLabel: "Money & compliance"),
            deletions: deletions,
            hasDeletions: !deletions.isEmpty,
            exports: exports,
            hasExports: !exports.isEmpty
        ))
    }

    @Sendable
    func processDeletion(req: Request) async throws -> Response {
        let admin = try req.auth.require(User.self)
        let requestID = try Self.uuid(req, "requestID")
        return try await Self.perform(req, back: "/admin/data-requests", section: .dataRequests, notice: "deletion-processed") {
            try await AdminService(db: req.db).processDeletion(requestID, by: admin.requireID())
        }
    }

    @Sendable
    func processExport(req: Request) async throws -> Response {
        let admin = try req.auth.require(User.self)
        let requestID = try Self.uuid(req, "requestID")
        return try await Self.perform(req, back: "/admin/data-requests", section: .dataRequests, notice: "export-processed") {
            try await AdminService(db: req.db).markExportProcessed(requestID, by: admin.requireID())
        }
    }

    // MARK: - Audit log

    struct AuditRowContext: Encodable {
        let when: String
        let adminName: String
        let adminInitials: String
        let action: Pill
        let targetType: String
        let targetID: String
        let targetURL: String?
        let details: String
    }

    struct AuditLogPageContext: Encodable {
        let title = "Admin · Audit log"
        let chrome: Chrome
        let rows: [AuditRowContext]
        let isEmpty: Bool
        let pager: Pager
    }

    @Sendable
    func auditLog(req: Request) async throws -> View {
        let (rows, total, page) = try await AdminService(db: req.db).auditLog(page: Self.page(req))
        let contexts = rows.map { row -> AuditRowContext in
            let targetID = row.targetID.uuidString
            let targetURL: String?
            switch row.targetType {
            case "user": targetURL = "/admin/users/\(targetID)"
            case "event": targetURL = "/events/\(targetID)"
            default: targetURL = nil
            }
            return AuditRowContext(
                when: row.createdAt.map(Self.formatTime) ?? "",
                adminName: row.adminUser.displayName,
                adminInitials: Self.initials(row.adminUser.displayName),
                action: Self.actionPill(row.action),
                targetType: row.targetType,
                targetID: targetID,
                targetURL: targetURL,
                details: Self.details(row.metadata)
            )
        }
        return try await req.view.render("admin/audit-log", AuditLogPageContext(
            chrome: try await Self.chrome(req, .auditLog, sectionLabel: "Money & compliance"),
            rows: contexts,
            isEmpty: contexts.isEmpty,
            pager: Pager(path: "/admin/audit-log", items: [], page: page, total: total, pageSize: AdminService.auditPageSize)
        ))
    }

    /// The action code ("event.cancelled") in a colour by kind: red for
    /// removals and suspensions, amber for plan changes, green for
    /// restores, teal otherwise.
    static func actionPill(_ action: String) -> Pill {
        switch action {
        case AdminService.Action.suspended, AdminService.Action.eventCancelled, AdminService.Action.deletionProcessed:
            return pill(action, .red)
        case AdminService.Action.planChanged:
            return pill(action, .gold)
        case AdminService.Action.unsuspended:
            return pill(action, .green)
        default:
            return pill(action, .teal)
        }
    }

    static func details(_ metadata: [String: String]) -> String {
        let parts: [String] = metadata.keys.sorted().map { (key: String) -> String in
            "\(key): \(metadata[key] ?? "")"
        }
        return parts.joined(separator: ", ")
    }

    static func historyRow(_ row: AdminAuditLog) -> HistoryContext {
        HistoryContext(
            when: row.createdAt.map(formatTime) ?? "",
            adminName: row.adminUser.displayName,
            action: actionPill(row.action),
            details: details(row.metadata)
        )
    }

    // MARK: - Helpers

    /// Runs an admin action. Success: `HX-Redirect` (or a 303) to `back`
    /// with a notice. An `APIError` (a rule the action broke) or an
    /// `Abort` (say, a row deleted in another tab) is shown to the admin:
    /// htmx doesn't swap a non-2xx response, so passing it through would
    /// make the click look like it did nothing. Anything else propagates.
    static func perform(
        _ req: Request,
        back: String,
        section: Section,
        notice: String,
        _ action: () async throws -> Void
    ) async throws -> Response {
        do {
            try await action()
        } catch let error as APIError {
            let message = error == .notFound ? "That no longer exists. Reload the page." : error.message
            return try await fail(req, message, back: back, section: section)
        } catch let abort as AbortError {
            return try await fail(req, abort.status == .notFound ? "That no longer exists. Reload the page." : abort.reason, back: back, section: section)
        }
        let target = withNotice(back, notice)
        if req.headers.first(name: "HX-Request") != nil {
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: "HX-Redirect", value: target)
            return response
        }
        return req.redirect(to: target)
    }

    /// Adds `notice=` to a URL, replacing an old one, so repeated actions
    /// on a list don't pile notices up in its address.
    static func withNotice(_ url: String, _ notice: String) -> String {
        let parts = url.split(separator: "?", maxSplits: 1).map(String.init)
        var items: [String] = parts.count > 1 ? parts[1].split(separator: "&").map(String.init) : []
        items.removeAll { $0.hasPrefix("notice=") }
        items.append("notice=\(notice)")
        let path: String = parts.first ?? url
        return path + "?" + items.joined(separator: "&")
    }

    static func fail(_ req: Request, _ message: String, back: String, section: Section) async throws -> Response {
        if req.headers.first(name: "HX-Request") != nil {
            let response = try await req.view.render("admin/alert", AlertContext(message: message)).encodeResponse(for: req)
            response.headers.replaceOrAdd(name: "HX-Retarget", value: "#admin-alert")
            // Scroll up to the message: the button may be far down a table.
            response.headers.replaceOrAdd(name: "HX-Reswap", value: "innerHTML show:window:top")
            return response
        }
        return try await req.view.render("admin/error", ErrorPageContext(
            chrome: try await chrome(req, section, sectionLabel: "Admin"),
            message: message,
            backURL: back
        )).encodeResponse(status: .badRequest, for: req)
    }

    /// Only an `/admin` path is accepted as a return target, so the form
    /// field can't send the admin off-site or break the header.
    static func safeReturn(_ value: String?, fallback: String) -> String {
        guard let value, value == "/admin" || value.hasPrefix("/admin/") || value.hasPrefix("/admin?"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else {
            return fallback
        }
        return value
    }

    static func uuid(_ req: Request, _ name: String) throws -> UUID {
        guard let text = req.parameters.get(name), let id = UUID(uuidString: text) else {
            throw Abort(.notFound)
        }
        return id
    }

    /// A fresh formatter per call: `DateFormatter` isn't documented
    /// thread-safe on Linux, and requests render concurrently.
    static func formatDay(_ date: Date) -> String {
        EventDateTag.makeFormatter("MMM d, yyyy", timeZone: nil).string(from: date)
    }

    static func formatTime(_ date: Date) -> String {
        EventDateTag.makeFormatter("MMM d, yyyy HH:mm 'UTC'", timeZone: nil).string(from: date)
    }
}

/// Sends a signed-out visitor to `/login`. For an htmx request (a search,
/// filter or chart swap after the session expired) a 303 would be followed
/// by htmx and the login page swapped into the admin page, so it answers
/// with `HX-Redirect` instead and the whole page goes to sign-in.
struct HTMXAwareSignInRedirect: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard !request.auth.has(User.self) else {
            return try await next.respond(to: request)
        }
        if request.headers.first(name: "HX-Request") != nil {
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: "HX-Redirect", value: "/login")
            return response
        }
        return request.redirect(to: "/login")
    }
}
