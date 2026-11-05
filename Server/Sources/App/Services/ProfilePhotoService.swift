import Fluent
import Foundation
import Vapor
import ExpatEventsAPI

/// Where a member's profile photo comes from (theme PR 2). Automatically:
/// their Google photo, then a photo they uploaded, then the default avatar.
/// Gravatar is **opt-in** (user's decision after the review: an automatic
/// Gravatar sends a hash of every member's email to gravatar.com and puts
/// it in every page that shows them), used only when picked on `/account`.
/// Sign in with Apple provides no photo.
enum PhotoSource: String, Codable, CaseIterable, Sendable {
    case automatic, google, gravatar, upload, none
}

/// Is there a Gravatar for this email hash? `nil` means it couldn't be
/// checked (network trouble).
protocol GravatarChecker: Sendable {
    func hasGravatar(hash: String) async -> Bool?
}

/// Asks gravatar.com with `d=404`, which answers 404 when the email has no
/// Gravatar. Short timeout: it can run during sign-in.
struct HTTPGravatarChecker: GravatarChecker {
    let client: any Client

    func hasGravatar(hash: String) async -> Bool? {
        do {
            let response = try await client.get(URI(string: "https://gravatar.com/avatar/\(hash)?d=404&s=8")) { request in
                request.timeout = .seconds(3)
            }
            switch response.status {
            case .ok: return true
            case .notFound: return false
            default: return nil
            }
        } catch {
            return nil
        }
    }
}

/// Stores uploaded photos and gives back the path they're served at.
protocol PhotoStorage: Sendable {
    func save(_ data: Data, fileExtension: String) async throws -> String
    func delete(path: String) async throws
    /// The file behind a served name, for the `/uploads/avatars/:name`
    /// route; nil if the name isn't one this storage makes.
    func localFile(named name: String) -> String?
}

/// Development storage (user's decision: local disk now, DigitalOcean
/// Spaces at M13): files in `Storage/uploads/avatars/`, outside `Public/`
/// so `FileMiddleware` never serves them; `PhotoUploadsController` does,
/// with locked-down headers. Names are random UUIDs, never anything the
/// member sent.
struct LocalPhotoStorage: PhotoStorage {
    let directory: String
    let urlPrefix: String

    static func isStoredName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, String(parts[0]) == parts[0].lowercased() else {
            return false
        }
        return ["jpg", "png", "webp"].contains(String(parts[1]))
    }

    func save(_ data: Data, fileExtension: String) async throws -> String {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString.lowercased()).\(fileExtension)"
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name), options: .atomic)
        return urlPrefix + name
    }

    /// Only deletes files this storage made (its prefix and a generated
    /// name), so a stored path can't reach anything else.
    func delete(path: String) async throws {
        guard path.hasPrefix(urlPrefix), let file = localFile(named: String(path.dropFirst(urlPrefix.count))) else { return }
        if FileManager.default.fileExists(atPath: file) {
            try FileManager.default.removeItem(atPath: file)
        }
    }

    func localFile(named name: String) -> String? {
        Self.isStoredName(name) ? URL(fileURLWithPath: directory).appendingPathComponent(name).path : nil
    }
}

/// Everything about profile photos: the Google photo saved at sign-in, the
/// opt-in Gravatar, uploads, the member's choice, and keeping
/// `User.photoURL` (what every page and DTO shows) in step with them.
struct ProfilePhotoService {
    let db: Database
    let storage: any PhotoStorage
    let gravatar: any GravatarChecker

    static let maxUploadBytes = 2 * 1024 * 1024
    /// How long a Gravatar answer is trusted before sign-in checks again
    /// (only for members who chose Gravatar).
    static let gravatarRecheckInterval: TimeInterval = 7 * 24 * 60 * 60

    // MARK: Resolving

    static func gravatarHash(_ email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func gravatarURL(for email: String) -> String {
        "https://gravatar.com/avatar/\(gravatarHash(email))?s=256&d=mp"
    }

    /// The photos this member could show right now. Gravatar only counts
    /// once they've opted in and it was found.
    static func available(_ user: User) -> [(PhotoSource, String)] {
        var options: [(PhotoSource, String)] = []
        if let google = user.googlePhotoURL { options.append((.google, google)) }
        if user.photoSource == .gravatar, user.gravatarAvailable == true, user.erasedAt == nil {
            options.append((.gravatar, gravatarURL(for: user.email)))
        }
        if let upload = user.uploadedPhotoPath { options.append((.upload, upload)) }
        return options
    }

    /// What `photoURL` should be: the chosen source if it's available,
    /// otherwise the automatic order (Google, then upload); nil means the
    /// default avatar.
    static func resolvedPhotoURL(_ user: User) -> String? {
        let options = available(user)
        let source = user.photoSource ?? .automatic
        if source == .none { return nil }
        if let chosen = options.first(where: { $0.0 == source }) { return chosen.1 }
        return options.first(where: { $0.0 != .gravatar })?.1
    }

    @discardableResult
    static func refresh(_ user: User) -> Bool {
        let resolved = resolvedPhotoURL(user)
        guard resolved != user.photoURL else { return false }
        user.photoURL = resolved
        return true
    }

    // MARK: Sign-in

    /// After any sign-in: keep the Google photo current (Google sign-ins
    /// only; Apple has none) and, for members who chose Gravatar, re-check
    /// it weekly. Never fails a sign-in over Gravatar: an unreachable
    /// gravatar.com keeps the previous answer and is retried an hour later.
    func updateAfterSignIn(_ user: User, provider: IdentityProvider, googlePicture: String?, now: Date = Date()) async throws {
        if provider == .google {
            user.googlePhotoURL = Self.safeRemoteURL(googlePicture)
        }
        if user.photoSource == .gravatar, user.erasedAt == nil,
           user.gravatarCheckedAt.map({ now.timeIntervalSince($0) > Self.gravatarRecheckInterval }) ?? true {
            await recordGravatarCheck(user, now: now)
        }
        Self.refresh(user)
        try await user.save(on: db)
    }

    /// Asks gravatar.com and records the answer. On no answer it keeps the
    /// old one and sets the check time so the next try is an hour away.
    private func recordGravatarCheck(_ user: User, now: Date) async {
        if let answer = await gravatar.hasGravatar(hash: Self.gravatarHash(user.email)) {
            user.gravatarAvailable = answer
            user.gravatarCheckedAt = now
        } else {
            user.gravatarCheckedAt = now.addingTimeInterval(-Self.gravatarRecheckInterval + 60 * 60)
        }
    }

    /// Only https photo URLs from the provider are kept.
    static func safeRemoteURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.lowercased().hasPrefix("https://"), value.count <= 2048 else { return nil }
        return value
    }

    // MARK: Choosing

    /// Picking Gravatar is the opt-in: only then is gravatar.com asked.
    func choose(_ source: PhotoSource, for user: User, now: Date = Date()) async throws {
        switch source {
        case .automatic, .none:
            break
        case .gravatar:
            guard let answer = await gravatar.hasGravatar(hash: Self.gravatarHash(user.email)) else {
                throw APIError(code: "gravatar_unreachable", message: "Couldn't reach gravatar.com. Try again in a moment.")
            }
            user.gravatarAvailable = answer
            user.gravatarCheckedAt = now
            guard answer else {
                try await user.save(on: db)
                throw APIError(code: "photo_unavailable", message: "No Gravatar was found for your email address at gravatar.com.")
            }
        case .google, .upload:
            guard Self.available(user).contains(where: { $0.0 == source }) else {
                throw APIError(code: "photo_unavailable", message: "That photo isn't available for your account.")
            }
        }
        user.photoSource = source
        Self.refresh(user)
        try await user.save(on: db)
    }

    // MARK: Uploading

    /// Checks and cleans the photo (`ImageSanitizer`: real JPEG/PNG/WebP,
    /// at most 4096 px a side, metadata such as GPS removed), saves it,
    /// shows it (an upload is an explicit choice), and removes the one it
    /// replaces. The account row is locked while it's updated, so two
    /// uploads at once can't leave an unreferenced file, and an account
    /// erased in the meantime is refused.
    func upload(_ data: Data, for user: User) async throws {
        guard !data.isEmpty else {
            throw APIError(code: "photo_missing", message: "Choose a photo to upload.")
        }
        guard data.count <= Self.maxUploadBytes else {
            throw APIError(code: "photo_too_large", message: "That photo is too large. The limit is 2 MB.")
        }
        let cleaned = try ImageSanitizer.clean(data)
        let userID = try user.requireID()
        let path = try await storage.save(cleaned.data, fileExtension: cleaned.type.rawValue)
        let previous: String?
        do {
            previous = try await db.transaction { tx -> String? in
                try await tx.lockRow(User.schema, id: userID)
                guard let current = try await User.find(userID, on: tx), current.erasedAt == nil else {
                    throw APIError.notFound
                }
                let old = current.uploadedPhotoPath
                current.uploadedPhotoPath = path
                current.photoSource = .upload
                Self.refresh(current)
                try await current.save(on: tx)
                return old
            }
        } catch {
            try? await storage.delete(path: path)
            throw error
        }
        user.uploadedPhotoPath = path
        user.photoSource = .upload
        Self.refresh(user)
        if let previous, previous != path {
            try? await storage.delete(path: previous)
        }
    }

    func removeUpload(for user: User) async throws {
        let userID = try user.requireID()
        let previous: String? = try await db.transaction { tx -> String? in
            try await tx.lockRow(User.schema, id: userID)
            guard let current = try await User.find(userID, on: tx), let old = current.uploadedPhotoPath else { return nil }
            current.uploadedPhotoPath = nil
            if current.photoSource == .upload { current.photoSource = .automatic }
            Self.refresh(current)
            try await current.save(on: tx)
            return old
        }
        guard let previous else { return }
        user.uploadedPhotoPath = nil
        if user.photoSource == .upload { user.photoSource = .automatic }
        Self.refresh(user)
        try? await storage.delete(path: previous)
    }
}
