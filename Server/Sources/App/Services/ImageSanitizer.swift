import Foundation
import ExpatEventsAPI

/// Checks an uploaded photo really is a well-formed JPEG, PNG or WebP of a
/// sensible size, and removes its metadata before it's stored (found by
/// the profile photos review: phone photos carry EXIF, often including the
/// GPS position they were taken at, and every visitor can download an
/// avatar). Pure Swift, no image library: the file is walked segment by
/// segment and only the parts needed to draw the picture are kept; the
/// pixel data itself is never decoded or changed.
///
/// - JPEG: drops every APPn segment except APP0 (JFIF), APP2 (colour
///   profile) and APP14 (Adobe colour transform), and drops comments. The
///   EXIF orientation, if any, is put back as a tiny EXIF block holding
///   only that, so phone photos aren't shown sideways.
/// - PNG: keeps only the chunks that affect how the image looks; drops
///   text, EXIF and time chunks.
/// - WebP: drops the EXIF and XMP chunks and clears their flags.
enum ImageSanitizer {
    enum ImageType: String, Sendable {
        case jpeg = "jpg", png, webp

        var contentType: String {
            switch self {
            case .jpeg: return "image/jpeg"
            case .png: return "image/png"
            case .webp: return "image/webp"
            }
        }
    }

    struct Cleaned {
        let data: Data
        let type: ImageType
        let width: Int
        let height: Int
    }

    /// Big enough for any avatar; keeps a small file from declaring a
    /// gigantic image that every viewer's browser would have to decode.
    static let maxDimension = 4096

    static let notAnImage = APIError(code: "photo_type", message: "Upload a JPEG, PNG or WebP image.")
    static let tooLarge = APIError(code: "photo_dimensions", message: "That photo is too large. Use one up to 4096 pixels on each side.")

    /// The type from the first bytes alone (not the file name or the
    /// browser's content type).
    static func type(of data: Data) -> ImageType? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return .jpeg }
        if bytes.count >= 8, bytes[0..<8].elementsEqual(pngSignature) { return .png }
        if bytes.count >= 12, bytes[0..<4].elementsEqual(Array("RIFF".utf8)), bytes[8..<12].elementsEqual(Array("WEBP".utf8)) { return .webp }
        return nil
    }

    static func clean(_ data: Data) throws -> Cleaned {
        let bytes = [UInt8](data)
        let cleaned: Cleaned
        switch type(of: data) {
        case .jpeg: cleaned = try cleanJPEG(bytes)
        case .png: cleaned = try cleanPNG(bytes)
        case .webp: cleaned = try cleanWebP(bytes)
        case nil: throw notAnImage
        }
        guard cleaned.width >= 1, cleaned.height >= 1 else { throw notAnImage }
        guard cleaned.width <= maxDimension, cleaned.height <= maxDimension else { throw tooLarge }
        return cleaned
    }

    // MARK: - Helpers

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
    private static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private static func le24(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 }
    private static func le32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }

    // MARK: - JPEG

    private static func cleanJPEG(_ b: [UInt8]) throws -> Cleaned {
        var out: [UInt8] = [0xFF, 0xD8]
        var i = 2
        var width = 0, height = 0
        var orientation: Int?
        var wroteOrientation = false
        while i < b.count {
            guard b[i] == 0xFF else { throw notAnImage }
            var m = i + 1
            while m < b.count, b[m] == 0xFF { m += 1 } // fill bytes
            guard m < b.count else { throw notAnImage }
            let marker = b[m]
            i = m + 1
            if marker == 0xD9 { // end of image
                out += [0xFF, 0xD9]
                break
            }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 { // no length
                out += [0xFF, marker]
                continue
            }
            guard i + 2 <= b.count else { throw notAnImage }
            let length = be16(b, i)
            guard length >= 2, i + length <= b.count else { throw notAnImage }
            let segment = Array(b[i..<(i + length)])
            if marker == 0xDA { // start of scan: the rest is image data
                if !wroteOrientation, let orientation {
                    out += orientationSegment(orientation)
                    wroteOrientation = true
                }
                out += [0xFF, marker]
                out += b[i...]
                guard width > 0 else { throw notAnImage }
                return Cleaned(data: Data(out), type: .jpeg, width: width, height: height)
            }
            let isFrame = (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
            if isFrame {
                guard length >= 7 else { throw notAnImage }
                height = be16(b, i + 3)
                width = be16(b, i + 5)
            }
            if marker == 0xE1 { // APP1: EXIF/XMP. Keep only the orientation.
                if orientation == nil { orientation = exifOrientation(segment) }
                i += length
                continue
            }
            let keepApp: Set<UInt8> = [0xE0, 0xE2, 0xEE]
            if (0xE0...0xEF).contains(marker) && !keepApp.contains(marker) || marker == 0xFE {
                i += length
                continue
            }
            if isFrame, !wroteOrientation, let orientation {
                out += orientationSegment(orientation)
                wroteOrientation = true
            }
            out += [0xFF, marker]
            out += segment
            i += length
        }
        guard width > 0 else { throw notAnImage }
        return Cleaned(data: Data(out), type: .jpeg, width: width, height: height)
    }

    /// The Orientation tag (0x0112) from an APP1 EXIF segment, if present
    /// and valid (1...8). `segment` starts with the 2 length bytes.
    static func exifOrientation(_ segment: [UInt8]) -> Int? {
        let header: [UInt8] = Array("Exif".utf8) + [0, 0]
        guard segment.count > 2 + 6 + 8, Array(segment[2..<8]).elementsEqual(header) else { return nil }
        let tiff = Array(segment[8...])
        let little: Bool
        if tiff[0] == 0x49, tiff[1] == 0x49 { little = true } else if tiff[0] == 0x4D, tiff[1] == 0x4D { little = false } else { return nil }
        func u16(_ o: Int) -> Int? { o + 2 <= tiff.count ? (little ? le16(tiff, o) : be16(tiff, o)) : nil }
        func u32(_ o: Int) -> Int? { o + 4 <= tiff.count ? (little ? le32(tiff, o) : be32(tiff, o)) : nil }
        guard let ifd = u32(4), let count = u16(ifd), count < 1000 else { return nil }
        for entry in 0..<count {
            let o = ifd + 2 + entry * 12
            guard let tag = u16(o) else { return nil }
            if tag == 0x0112, let value = u16(o + 8), (1...8).contains(value) {
                return value
            }
        }
        return nil
    }

    /// A minimal APP1 EXIF segment holding only the orientation.
    static func orientationSegment(_ orientation: Int) -> [UInt8] {
        var exif: [UInt8] = Array("Exif".utf8) + [0, 0]
        exif += [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08] // big-endian TIFF, IFD at 8
        exif += [0x00, 0x01]                                    // one entry
        exif += [0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01] // Orientation, SHORT, count 1
        exif += [0x00, UInt8(orientation), 0x00, 0x00]           // value
        exif += [0x00, 0x00, 0x00, 0x00]                         // no next IFD
        let length = exif.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + exif
    }

    // MARK: - PNG

    /// Chunks that affect how the image is drawn (including animation).
    private static let keptPNGChunks: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "sBIT", "pHYs", "bKGD",
        "acTL", "fcTL", "fdAT",
    ]

    private static func cleanPNG(_ b: [UInt8]) throws -> Cleaned {
        var out = pngSignature
        var i = 8
        var width = 0, height = 0
        var sawEnd = false
        while i + 12 <= b.count {
            let length = be32(b, i)
            guard length >= 0, length <= b.count, i + 12 + length <= b.count else { throw notAnImage }
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            if i == 8 {
                guard type == "IHDR", length == 13 else { throw notAnImage }
                width = be32(b, i + 8)
                height = be32(b, i + 12)
            }
            if keptPNGChunks.contains(type) {
                out += b[i..<(i + 12 + length)] // length, type, data and CRC, unchanged
            }
            i += 12 + length
            if type == "IEND" {
                sawEnd = true
                break
            }
        }
        guard sawEnd, width > 0 else { throw notAnImage }
        return Cleaned(data: Data(out), type: .png, width: width, height: height)
    }

    // MARK: - WebP

    private static func cleanWebP(_ b: [UInt8]) throws -> Cleaned {
        guard b.count >= 20 else { throw notAnImage }
        var chunks: [[UInt8]] = []
        var i = 12
        var width = 0, height = 0
        let end = min(b.count, 8 + le32(b, 4))
        while i + 8 <= end {
            let fourCC = String(decoding: b[i..<(i + 4)], as: UTF8.self)
            let size = le32(b, i + 4)
            let padded = size + (size & 1)
            guard size >= 0, i + 8 + size <= b.count else { throw notAnImage }
            var chunk = Array(b[i..<min(i + 8 + padded, b.count)])
            if chunk.count < 8 + padded { chunk += [UInt8](repeating: 0, count: 8 + padded - chunk.count) }
            switch fourCC {
            case "VP8X":
                guard size >= 10 else { throw notAnImage }
                chunk[8] &= ~UInt8(0x08 | 0x04) // no EXIF, no XMP
                width = le24(b, i + 12) + 1
                height = le24(b, i + 15) + 1
            case "VP8 ":
                guard size >= 10, b[i + 11] == 0x9D, b[i + 12] == 0x01, b[i + 13] == 0x2A else { throw notAnImage }
                if width == 0 {
                    width = le16(b, i + 14) & 0x3FFF
                    height = le16(b, i + 16) & 0x3FFF
                }
            case "VP8L":
                guard size >= 5, b[i + 8] == 0x2F else { throw notAnImage }
                if width == 0 {
                    let bits = le32(b, i + 9)
                    width = (bits & 0x3FFF) + 1
                    height = ((bits >> 14) & 0x3FFF) + 1
                }
            default:
                break
            }
            if fourCC != "EXIF" && fourCC != "XMP " {
                chunks.append(chunk)
            }
            i += 8 + padded
        }
        guard width > 0 else { throw notAnImage }
        let body = chunks.flatMap { $0 }
        let riffSize = 4 + body.count
        var out: [UInt8] = Array("RIFF".utf8)
        out += [UInt8(riffSize & 0xFF), UInt8((riffSize >> 8) & 0xFF), UInt8((riffSize >> 16) & 0xFF), UInt8((riffSize >> 24) & 0xFF)]
        out += Array("WEBP".utf8)
        out += body
        return Cleaned(data: Data(out), type: .webp, width: width, height: height)
    }
}
