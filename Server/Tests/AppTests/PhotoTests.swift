@testable import App
import ExpatEventsAPI
import XCTVapor
import Fluent

/// Theme PR 2: profile photos from Google, an upload or (opt-in) Gravatar,
/// with a choice on /account. No test uses the network: Gravatar answers
/// come from `FixedGravatarChecker`, and uploads go to a temporary folder.
final class PhotoTests: XCTestCase {
    func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
            try await app.autoRevert()
        } catch {
            try await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func makeUser(db: Database, email: String) async throws -> User {
        let user = User(displayName: email, email: email,
                        privacyPolicyVersion: LegalVersions.privacyPolicy, termsVersion: LegalVersions.terms)
        try await user.save(on: db)
        try await Subscription(userID: try user.requireID(), plan: .free, status: .active).save(on: db)
        return user
    }

    private func sessionCookie(for user: User, db: Database) async throws -> String {
        var data = SessionData()
        data["_UserSession"] = try user.requireID().uuidString
        let key = SessionID(string: UUID().uuidString)
        try await SessionRecord(key: key, data: data).create(on: db)
        return "vapor-session=\(key.string)"
    }

    // MARK: - Test images (structure only; the pixel data is never decoded)

    static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }

    static func pngChunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        be32(data.count) + Array(type.utf8) + data + [0, 0, 0, 0] // CRC isn't checked
    }

    static func png(width: Int = 64, height: Int = 64, extra: [[UInt8]] = []) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += pngChunk("IHDR", be32(width) + be32(height) + [8, 6, 0, 0, 0])
        for chunk in extra { bytes += chunk }
        bytes += pngChunk("IDAT", [0x78, 0x9C, 0x01])
        bytes += pngChunk("IEND", [])
        return Data(bytes)
    }

    /// An APP1 EXIF segment with an orientation and a fake GPS marker.
    static func exifSegment(orientation: UInt8) -> [UInt8] {
        var body: [UInt8] = Array("Exif".utf8) + [0, 0]
        body += [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00, 0x01]
        body += [0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, orientation, 0x00, 0x00]
        body += [0x00, 0x00, 0x00, 0x00]
        body += Array("GPS 51.5007N 0.1246W".utf8)
        let length = body.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + body
    }

    static func jpeg(width: Int = 64, height: Int = 48, orientation: UInt8? = nil, comment: String? = nil) -> Data {
        var bytes: [UInt8] = [0xFF, 0xD8]
        bytes += [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        if let orientation { bytes += exifSegment(orientation: orientation) }
        if let comment {
            let text = Array(comment.utf8)
            bytes += [0xFF, 0xFE, UInt8((text.count + 2) >> 8), UInt8((text.count + 2) & 0xFF)] + text
        }
        bytes += [0xFF, 0xC0, 0x00, 0x11, 0x08, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 3,
                  1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]
        bytes += [0xFF, 0xDA, 0x00, 0x0C, 3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0, 0x12, 0x34, 0x56]
        bytes += [0xFF, 0xD9]
        return Data(bytes)
    }

    static func webp(width: Int = 64, height: Int = 64, withEXIF: Bool = true) -> Data {
        var chunks: [UInt8] = []
        let vp8x: [UInt8] = [0x08 | 0x04, 0, 0, 0] + Array(le32(width - 1).prefix(3)) + Array(le32(height - 1).prefix(3))
        chunks += Array("VP8X".utf8) + le32(vp8x.count) + vp8x
        let vp8l: [UInt8] = [0x2F] + le32((width - 1) | (height - 1) << 14) + [0, 0, 0]
        chunks += Array("VP8L".utf8) + le32(vp8l.count) + vp8l
        if withEXIF {
            let exif = Array("GPS 51.5N".utf8) + [0]
            chunks += Array("EXIF".utf8) + le32(exif.count) + exif
        }
        return Data(Array("RIFF".utf8) + le32(4 + chunks.count) + Array("WEBP".utf8) + chunks)
    }

    private func contains(_ data: Data, _ text: String) -> Bool {
        data.range(of: Data(text.utf8)) != nil
    }

    /// A multipart/form-data body with one file field, as a browser sends it.
    private func multipart(_ data: Data, field: String = "photo", filename: String = "me.png", type: String = "image/png") -> (HTTPHeaders, ByteBuffer) {
        let boundary = "TestBoundary\(UUID().uuidString.prefix(8))"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (["Content-Type": "multipart/form-data; boundary=\(boundary)"], ByteBuffer(bytes: body))
    }

    private func storedFile(_ app: Application, path: String) -> String? {
        app.photoStorage.localFile(named: String(path.dropFirst("/uploads/avatars/".count)))
    }

    private func fileExists(_ app: Application, path: String) -> Bool {
        storedFile(app, path: path).map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    // MARK: - Image checks

    /// Uploads are recognized by content, metadata is removed (the JPEG's
    /// orientation is kept), and absurd sizes or broken files are refused.
    func testImageSanitizerRemovesMetadataAndChecksSize() throws {
        XCTAssertNil(ImageSanitizer.type(of: Data("<html><script>".utf8)))
        XCTAssertNil(ImageSanitizer.type(of: Data("<svg xmlns=".utf8)))

        let photo = Self.jpeg(width: 640, height: 480, orientation: 6, comment: "Shot on my phone at home")
        XCTAssertTrue(contains(photo, "GPS"))
        let jpeg = try ImageSanitizer.clean(photo)
        XCTAssertEqual(jpeg.type, .jpeg)
        XCTAssertEqual(jpeg.width, 640)
        XCTAssertEqual(jpeg.height, 480)
        XCTAssertFalse(contains(jpeg.data, "GPS"), "EXIF (and its GPS) is gone.")
        XCTAssertFalse(contains(jpeg.data, "my phone"), "Comments are gone.")
        XCTAssertTrue(contains(jpeg.data, "JFIF"), "Drawing-related segments stay.")
        let rewritten = try XCTUnwrap(jpeg.data.range(of: Data("Exif".utf8)))
        let segment = [UInt8](jpeg.data[(rewritten.lowerBound - 2)...])
        XCTAssertEqual(ImageSanitizer.exifOrientation(segment), 6, "Only the orientation is put back.")
        XCTAssertEqual(jpeg.data.suffix(2), Data([0xFF, 0xD9]))

        let png = try ImageSanitizer.clean(Self.png(width: 300, height: 200, extra: [
            Self.pngChunk("tEXt", Array("Author\0Jane Doe".utf8)),
            Self.pngChunk("eXIf", Array("GPS".utf8)),
            Self.pngChunk("gAMA", [0, 0, 0xB1, 0x8F]),
        ]))
        XCTAssertEqual(png.width, 300)
        XCTAssertFalse(contains(png.data, "Jane Doe"))
        XCTAssertFalse(contains(png.data, "GPS"))
        XCTAssertTrue(contains(png.data, "gAMA"))

        let webp = try ImageSanitizer.clean(Self.webp(width: 128, height: 96))
        XCTAssertEqual(webp.width, 128)
        XCTAssertEqual(webp.height, 96)
        XCTAssertFalse(contains(webp.data, "GPS"))
        let bytes = [UInt8](webp.data)
        XCTAssertEqual(bytes[20] & 0x0C, 0, "The EXIF/XMP flags are cleared.")
        XCTAssertEqual(Int(bytes[4]) | Int(bytes[5]) << 8, bytes.count - 8, "The RIFF size matches.")

        XCTAssertThrowsError(try ImageSanitizer.clean(Self.png(width: 5000, height: 10))) { error in
            XCTAssertEqual((error as? APIError)?.code, "photo_dimensions")
        }
        XCTAssertThrowsError(try ImageSanitizer.clean(Self.png().prefix(30)), "A cut-off file is refused.")
        XCTAssertThrowsError(try ImageSanitizer.clean(Data([0xFF, 0xD8, 0xFF, 0xE0])))
    }

    // MARK: - Resolving and sign-in

    /// Automatic is Google, then upload, then the default; Gravatar only
    /// when chosen (opt-in); a chosen photo that's gone falls back.
    func testPhotoResolutionOrderAndChoice() async throws {
        try await withApp { app in
            let user = try await makeUser(db: app.db, email: "order@example.com")
            XCTAssertNil(ProfilePhotoService.resolvedPhotoURL(user), "Nothing yet: the default avatar.")

            user.uploadedPhotoPath = "/uploads/avatars/a.png"
            XCTAssertEqual(ProfilePhotoService.resolvedPhotoURL(user), "/uploads/avatars/a.png")
            user.gravatarAvailable = true
            XCTAssertEqual(ProfilePhotoService.resolvedPhotoURL(user), "/uploads/avatars/a.png", "Gravatar isn't automatic.")
            user.googlePhotoURL = "https://lh3.googleusercontent.com/a/me"
            XCTAssertEqual(ProfilePhotoService.resolvedPhotoURL(user), "https://lh3.googleusercontent.com/a/me")

            user.photoSource = .gravatar
            XCTAssertEqual(ProfilePhotoService.resolvedPhotoURL(user), ProfilePhotoService.gravatarURL(for: "order@example.com"), "Opted in.")
            user.photoSource = .upload
            XCTAssertEqual(ProfilePhotoService.resolvedPhotoURL(user), "/uploads/avatars/a.png", "A choice beats the order.")
            user.photoSource = PhotoSource.none
            XCTAssertNil(ProfilePhotoService.resolvedPhotoURL(user), "The default icon, even with photos available.")
            user.photoSource = .upload
            user.uploadedPhotoPath = nil
            XCTAssertEqual(ProfilePhotoService.resolvedPhotoURL(user), "https://lh3.googleusercontent.com/a/me", "Chosen photo gone: back to the order.")
        }
    }

    /// Sign-in keeps the Google photo current (https only); an Apple
    /// sign-in leaves it alone; gravatar.com is only asked for members who
    /// chose Gravatar, and an unreachable gravatar.com keeps the old answer.
    func testSignInUpdatesGooglePhotoAndOnlyChecksGravatarWhenChosen() async throws {
        try await withApp { app in
            let user = try await makeUser(db: app.db, email: "signin@example.com")
            let now = Date()
            let service = ProfilePhotoService(db: app.db, storage: app.photoStorage, gravatar: FixedGravatarChecker(answer: true))

            try await service.updateAfterSignIn(user, provider: .google, googlePicture: "https://lh3.googleusercontent.com/a/one", now: now)
            XCTAssertEqual(user.googlePhotoURL, "https://lh3.googleusercontent.com/a/one")
            XCTAssertEqual(user.photoURL, "https://lh3.googleusercontent.com/a/one")
            XCTAssertNil(user.gravatarCheckedAt, "Not opted in: gravatar.com isn't asked.")

            try await service.updateAfterSignIn(user, provider: .apple, googlePicture: nil, now: now)
            XCTAssertEqual(user.googlePhotoURL, "https://lh3.googleusercontent.com/a/one", "Apple sign-in doesn't clear it.")

            try await service.updateAfterSignIn(user, provider: .google, googlePicture: "http://insecure.example/a.jpg", now: now)
            XCTAssertNil(user.googlePhotoURL, "Only https photos are kept.")
            XCTAssertNil(user.photoURL)

            try await service.choose(.gravatar, for: user, now: now)
            XCTAssertEqual(user.photoURL, ProfilePhotoService.gravatarURL(for: "signin@example.com"))

            let failing = ProfilePhotoService(db: app.db, storage: app.photoStorage, gravatar: FixedGravatarChecker(answer: nil))
            let later = now.addingTimeInterval(8 * 24 * 3600)
            try await failing.updateAfterSignIn(user, provider: .apple, googlePicture: nil, now: later)
            XCTAssertEqual(user.gravatarAvailable, true, "Unreachable: the old answer stays.")
            XCTAssertEqual(user.photoURL, ProfilePhotoService.gravatarURL(for: "signin@example.com"))

            let gone = ProfilePhotoService(db: app.db, storage: app.photoStorage, gravatar: FixedGravatarChecker(answer: false))
            try await gone.updateAfterSignIn(user, provider: .apple, googlePicture: nil, now: later.addingTimeInterval(2 * 3600))
            XCTAssertEqual(user.gravatarAvailable, false, "Retried an hour later: now gone.")
            XCTAssertNil(user.photoURL)
            let saved = try await User.find(try user.requireID(), on: app.db)
            XCTAssertNil(saved?.photoURL, "Saved, not just in memory.")
        }
    }

    // MARK: - Uploads

    /// Uploading from /account stores a cleaned copy, shows it, and
    /// replaces the previous upload; non-images and oversized files are
    /// refused with a message; removing it deletes the file.
    func testUploadReplaceAndRemoveAPhoto() async throws {
        try await withApp { app in
            let user = try await makeUser(db: app.db, email: "upload@example.com")
            let userID = try user.requireID()
            let cookie = try await sessionCookie(for: user, db: app.db)

            var (headers, body) = multipart(Self.png(extra: [Self.pngChunk("tEXt", Array("Secret\0note".utf8))]))
            headers.add(name: "Cookie", value: cookie)
            try await app.test(.POST, "/account/photo", headers: headers, body: body) { res async in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/account?photo=uploaded#photo")
            }
            let first = try await User.find(userID, on: app.db)
            let firstPath = try XCTUnwrap(first?.uploadedPhotoPath)
            XCTAssertTrue(firstPath.hasPrefix("/uploads/avatars/") && firstPath.hasSuffix(".png"))
            XCTAssertEqual(first?.photoURL, firstPath)
            XCTAssertEqual(first?.photoSource, .upload)
            let stored = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(storedFile(app, path: firstPath))))
            XCTAssertFalse(contains(stored, "Secret"), "The stored copy is the cleaned one.")

            try await app.test(.GET, firstPath) { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.contentType, .png)
                XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
                XCTAssertTrue(res.headers.first(name: "Content-Security-Policy")?.contains("sandbox") == true)
            }

            (headers, body) = multipart(Self.jpeg(orientation: 3), filename: "me.jpg", type: "image/jpeg")
            headers.add(name: "Cookie", value: cookie)
            try await app.test(.POST, "/account/photo", headers: headers, body: body) { res async in
                XCTAssertEqual(res.status, .seeOther)
            }
            let second = try await User.find(userID, on: app.db)
            let secondPath = try XCTUnwrap(second?.uploadedPhotoPath)
            XCTAssertTrue(secondPath.hasSuffix(".jpg"))
            XCTAssertFalse(fileExists(app, path: firstPath), "The replaced photo is deleted.")

            for (data, message) in [(Data("<html><script>alert(1)</script>".utf8), "Upload a JPEG, PNG or WebP image."),
                                    (Self.png(width: 9000, height: 9000), "4096 pixels"),
                                    (Self.png() + Data(repeating: 0, count: ProfilePhotoService.maxUploadBytes), "The limit is 2 MB.")] {
                (headers, body) = multipart(data)
                headers.add(name: "Cookie", value: cookie)
                try await app.test(.POST, "/account/photo", headers: headers, body: body) { res async in
                    XCTAssertEqual(res.status, .unprocessableEntity)
                    XCTAssertTrue(res.body.string.contains(message), message)
                }
            }
            let unchanged = try await User.find(userID, on: app.db)
            XCTAssertEqual(unchanged?.uploadedPhotoPath, secondPath, "Refused uploads change nothing.")

            try await app.test(.POST, "/account/photo/remove", headers: ["Cookie": cookie, "HX-Request": "true"]) { res async in
                XCTAssertEqual(res.headers.first(name: "HX-Redirect"), "/account?photo=removed#photo")
            }
            let removed = try await User.find(userID, on: app.db)
            XCTAssertNil(removed?.uploadedPhotoPath)
            XCTAssertNil(removed?.photoURL)
            XCTAssertEqual(removed?.photoSource, .automatic)
            XCTAssertFalse(fileExists(app, path: secondPath))
        }
    }

    /// Only names the storage generates are served from /uploads/avatars/.
    func testOnlyStoredPhotoNamesAreServed() async throws {
        try await withApp { app in
            for path in ["/uploads/avatars/..%2F..%2Fetc%2Fpasswd", "/uploads/avatars/not-a-uuid.png",
                         "/uploads/avatars/\(UUID().uuidString.lowercased()).html",
                         "/uploads/avatars/\(UUID().uuidString.lowercased()).png"] {
                try await app.test(.GET, path) { res async in
                    // A ".." path is refused by Vapor's FileMiddleware (403)
                    // before it reaches the route; the rest by the route (404).
                    XCTAssertTrue([HTTPResponseStatus.notFound, .forbidden].contains(res.status), "\(path): \(res.status)")
                }
            }
            XCTAssertTrue(LocalPhotoStorage.isStoredName("\(UUID().uuidString.lowercased()).webp"))
            XCTAssertFalse(LocalPhotoStorage.isStoredName("\(UUID().uuidString).webp"), "Generated names are lower-case.")
            XCTAssertFalse(LocalPhotoStorage.isStoredName("../x.png"))
        }
    }

    // MARK: - The account page

    /// The account page lists every source; Gravatar is opt-in (choosing
    /// it asks gravatar.com); an unavailable choice is refused.
    func testChoosingAPhotoOnTheAccountPage() async throws {
        try await withApp { app in
            let user = try await makeUser(db: app.db, email: "choose@example.com")
            let userID = try user.requireID()
            let cookie = try await sessionCookie(for: user, db: app.db)
            let form: HTTPHeaders = ["Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"]

            try await app.test(.GET, "/account", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Profile photo"))
                XCTAssertTrue(html.contains(#"value="automatic" checked"#))
                XCTAssertTrue(html.contains(#"value="gravatar""#), "Gravatar is always offered (opt-in).")
                XCTAssertTrue(html.contains("From your Google account, updated each time you sign in with Google."),
                              "The same wording whether or not a Google photo is available.")
                XCTAssertFalse(html.contains("Sign in with Apple"))
                XCTAssertTrue(html.contains(#"enctype="multipart/form-data""#))
            }
            let unchecked = try await User.find(userID, on: app.db)
            XCTAssertNil(unchecked?.gravatarCheckedAt, "Viewing the page doesn't ask gravatar.com.")

            try await app.test(.POST, "/account/photo/source", headers: form, body: .init(string: "source=google")) { res async in
                XCTAssertEqual(res.status, .unprocessableEntity)
                XCTAssertTrue(res.body.string.contains("available for your account"))
            }
            try await app.test(.POST, "/account/photo/source", headers: form, body: .init(string: "source=gravatar")) { res async in
                XCTAssertEqual(res.status, .unprocessableEntity)
                XCTAssertTrue(res.body.string.contains("No Gravatar was found"))
            }
            app.gravatarChecker = FixedGravatarChecker(answer: nil)
            try await app.test(.POST, "/account/photo/source", headers: form, body: .init(string: "source=gravatar")) { res async in
                XCTAssertTrue(res.body.string.contains("reach gravatar.com"))
            }
            app.gravatarChecker = FixedGravatarChecker(answer: true)
            try await app.test(.POST, "/account/photo/source", headers: form, body: .init(string: "source=gravatar")) { res async in
                XCTAssertEqual(res.headers.first(name: .location), "/account?photo=chosen#photo")
            }
            let opted = try await User.find(userID, on: app.db)
            XCTAssertEqual(opted?.photoURL, ProfilePhotoService.gravatarURL(for: "choose@example.com"))

            try await app.test(.POST, "/account/photo/source", headers: form, body: .init(string: "source=none")) { res async in
                XCTAssertEqual(res.headers.first(name: .location), "/account?photo=chosen#photo")
            }
            let none = try await User.find(userID, on: app.db)
            XCTAssertEqual(none?.photoSource, PhotoSource.none)
            XCTAssertNil(none?.photoURL)
            try await app.test(.GET, "/account?photo=chosen", headers: ["Cookie": cookie]) { res async in
                XCTAssertTrue(res.body.string.contains("Profile photo updated."))
                XCTAssertTrue(res.body.string.contains(#"value="none" checked"#))
                XCTAssertTrue(res.body.string.contains(#"referrerpolicy="no-referrer""#), "Google photos need no Referer.")
            }
        }
    }

    // MARK: - Erasure and export

    /// Erasing an account deletes its uploaded photo and every photo
    /// field; the data export lists the photo settings.
    func testErasureDeletesTheUploadedPhotoAndExportListsIt() async throws {
        try await withApp { app in
            let user = try await makeUser(db: app.db, email: "erase-photo@example.com")
            let service = ProfilePhotoService(db: app.db, storage: app.photoStorage, gravatar: FixedGravatarChecker(answer: true))
            try await service.upload(Self.png(), for: user)
            user.googlePhotoURL = "https://lh3.googleusercontent.com/a/x"
            try await user.save(on: app.db)
            let path = try XCTUnwrap(user.uploadedPhotoPath)

            let account = AccountService(db: app.db, photoStorage: app.photoStorage)
            let export = try await account.exportData(for: user)
            XCTAssertEqual(export.profile.photoSource, "upload")
            XCTAssertEqual(export.profile.uploadedPhotoURL, path)
            XCTAssertEqual(export.profile.googlePhotoURL, "https://lh3.googleusercontent.com/a/x")
            XCTAssertFalse(export.profile.gravatarOptedIn)

            try await account.process(try await account.requestDeletion(for: try user.requireID()))
            let erased = try await User.find(try user.requireID(), on: app.db)
            XCTAssertNil(erased?.photoURL)
            XCTAssertNil(erased?.uploadedPhotoPath)
            XCTAssertNil(erased?.googlePhotoURL)
            XCTAssertFalse(fileExists(app, path: path))

            // Uploading to an erased account is refused, and leaves no file.
            let directory = try XCTUnwrap((app.photoStorage as? LocalPhotoStorage)?.directory)
            let before = (try? FileManager.default.contentsOfDirectory(atPath: directory).count) ?? 0
            do {
                try await service.upload(Self.png(), for: try XCTUnwrap(erased))
                XCTFail("An erased account can't upload.")
            } catch {}
            let after = (try? FileManager.default.contentsOfDirectory(atPath: directory).count) ?? 0
            XCTAssertEqual(after, before)
        }
    }

    /// Google sign-in only uses an email Google has verified (accounts
    /// are linked by email).
    func testGoogleUnverifiedEmailIsNotUsedForLinking() throws {
        let verified = GoogleIdentityTokenVerifier.TokenInfoResponse(aud: "a", sub: "1", email: "x@example.com", emailVerified: "true", exp: "0", picture: nil)
        let unverified = GoogleIdentityTokenVerifier.TokenInfoResponse(aud: "a", sub: "1", email: "x@example.com", emailVerified: "false", exp: "0", picture: nil)
        XCTAssertEqual(GoogleIdentityTokenVerifier.linkableEmail(verified), "x@example.com")
        XCTAssertNil(GoogleIdentityTokenVerifier.linkableEmail(unverified))
    }
}
