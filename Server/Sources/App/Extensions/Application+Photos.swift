import Vapor

extension Application {
    private struct PhotoStorageKey: StorageKey {
        typealias Value = any PhotoStorage
    }

    private struct GravatarCheckerKey: StorageKey {
        typealias Value = any GravatarChecker
    }

    /// Where uploaded profile photos go (`configurePhotos`). Tests can
    /// replace it.
    var photoStorage: any PhotoStorage {
        get {
            guard let existing = storage[PhotoStorageKey.self] else {
                fatalError("PhotoStorage not configured: call configurePhotos(app) first.")
            }
            return existing
        }
        set { storage[PhotoStorageKey.self] = newValue }
    }

    var gravatarChecker: any GravatarChecker {
        get {
            guard let existing = storage[GravatarCheckerKey.self] else {
                fatalError("GravatarChecker not configured: call configurePhotos(app) first.")
            }
            return existing
        }
        set { storage[GravatarCheckerKey.self] = newValue }
    }
}

extension Request {
    var profilePhotos: ProfilePhotoService {
        ProfilePhotoService(db: db, storage: application.photoStorage, gravatar: application.gravatarChecker)
    }
}

/// Never asks gravatar.com (tests must not use the network); answers
/// whatever the test sets.
struct FixedGravatarChecker: GravatarChecker {
    var answer: Bool?

    func hasGravatar(hash: String) async -> Bool? {
        answer
    }
}

/// Local disk under `Storage/uploads/avatars/` (git-ignored, outside
/// `Public/`) until M13 adds DigitalOcean Spaces; tests write to a
/// temporary folder instead and never ask gravatar.com.
func configurePhotos(_ app: Application) {
    if app.environment == .testing {
        let directory = NSTemporaryDirectory() + "expatevents-test-uploads/avatars/"
        app.photoStorage = LocalPhotoStorage(directory: directory, urlPrefix: "/uploads/avatars/")
        app.gravatarChecker = FixedGravatarChecker(answer: false)
    } else {
        app.photoStorage = LocalPhotoStorage(
            directory: app.directory.workingDirectory + "Storage/uploads/avatars/",
            urlPrefix: "/uploads/avatars/"
        )
        app.gravatarChecker = HTTPGravatarChecker(client: app.client)
    }
}
