import Vapor

/// `GET /uploads/avatars/:name`: serves uploaded profile photos (theme
/// PR 2). A route rather than `FileMiddleware` (found by the review: the
/// middleware decodes `%`-escapes and extra slashes, so header checks on
/// the raw path could be skipped). Only names the storage itself
/// generates are served, always as an image with headers that stop a
/// browser from treating the file as anything else.
struct PhotoUploadsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("uploads", "avatars", ":name", use: serve)
    }

    @Sendable
    func serve(req: Request) async throws -> Response {
        guard let name = req.parameters.get("name"),
              let file = req.application.photoStorage.localFile(named: name),
              FileManager.default.fileExists(atPath: file)
        else {
            throw Abort(.notFound)
        }
        let buffer = try await req.fileio.collectFile(at: file)
        var headers = HTTPHeaders()
        switch name.split(separator: ".").last.map(String.init) {
        case "png": headers.contentType = .png
        case "webp": headers.contentType = HTTPMediaType(type: "image", subType: "webp")
        default: headers.contentType = .jpeg
        }
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        headers.replaceOrAdd(name: "Content-Security-Policy", value: "default-src 'none'; img-src 'self'; sandbox")
        // Names are random and never reused, so a photo can be cached for good.
        headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=31536000, immutable")
        return Response(status: .ok, headers: headers, body: .init(buffer: buffer))
    }
}
