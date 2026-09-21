import Foundation
import Darwin
import ImageIO
import CoreGraphics

/// Reads PE resources as data only. No executable code or Wine client runs.
/// RVA mapping follows the PE section table; directory offsets are relative to
/// the resource root. Fixed depth, byte and entry budgets bound malformed input.
enum CyderPEIcon {
    enum Failure: Error { case invalid }
    private final class Reader {
        let fd: Int32
        let size: Int
        var budget = 8 * 1024 * 1024
        let identity: stat
        init(_ url: URL) throws {
            fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.invalid }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 64 else {
                close(fd); throw Failure.invalid
            }
            identity = info; size = Int(info.st_size)
        }
        deinit { close(fd) }
        func read(_ offset: Int, _ count: Int) throws -> Data {
            guard offset >= 0, count >= 0, count <= budget, offset <= size, count <= size - offset else { throw Failure.invalid }
            budget -= count
            var data = Data(count: count)
            let actual = data.withUnsafeMutableBytes { bytes in pread(fd, bytes.baseAddress, count, off_t(offset)) }
            guard actual == count else { throw Failure.invalid }
            return data
        }
        func unchanged() -> Bool {
            var now = stat()
            return fstat(fd, &now) == 0 && now.st_size == identity.st_size
                && now.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec && now.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec
                && now.st_ctimespec.tv_sec == identity.st_ctimespec.tv_sec && now.st_ctimespec.tv_nsec == identity.st_ctimespec.tv_nsec
        }
    }
    private struct Section { let rva: Int; let size: Int; let offset: Int }
    private static func u16(_ data: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= data.count else { throw Failure.invalid }
        return Int(data[offset]) | Int(data[offset + 1]) << 8
    }
    private static func u32(_ data: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= data.count else { throw Failure.invalid }
        return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
    }
    private static func append32(_ value: Int, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> shift) & 255)) }
    }
    static func extract(from url: URL) throws -> CGImage {
        precondition(!Thread.isMainThread)
        let reader = try Reader(url)
        let dos = try reader.read(0, 64)
        guard try u16(dos, 0) == 0x5a4d else { throw Failure.invalid }
        let peOffset = try u32(dos, 60)
        let pe = try reader.read(peOffset, 24)
        guard try u32(pe, 0) == 0x4550 else { throw Failure.invalid }
        let sectionCount = try u16(pe, 6), optionalSize = try u16(pe, 20)
        guard sectionCount > 0, sectionCount <= 96, optionalSize <= 4096 else { throw Failure.invalid }
        let optional = try reader.read(peOffset + 24, optionalSize)
        let magic = try u16(optional, 0)
        guard magic == 0x10b || magic == 0x20b else { throw Failure.invalid }
        let directory = magic == 0x10b ? 96 : 112
        guard try u32(optional, directory - 4) >= 3 else { throw Failure.invalid }
        let resourceRVA = try u32(optional, directory + 16), resourceSize = try u32(optional, directory + 20)
        guard resourceRVA > 0, resourceSize >= 16 else { throw Failure.invalid }
        let sectionData = try reader.read(peOffset + 24 + optionalSize, sectionCount * 40)
        var sections: [Section] = []
        for index in 0..<sectionCount {
            let base = index * 40
            sections.append(Section(rva: try u32(sectionData, base + 12), size: try u32(sectionData, base + 16), offset: try u32(sectionData, base + 20)))
        }
        func fileOffset(_ rva: Int, _ length: Int) throws -> Int {
            let matches = sections.filter { rva >= $0.rva && rva - $0.rva <= $0.size && length <= $0.size - (rva - $0.rva) }
            guard matches.count == 1, let section = matches.first else { throw Failure.invalid }
            return section.offset + rva - section.rva
        }
        func resource(_ relative: Int, _ length: Int) throws -> Data {
            guard relative >= 0, relative <= resourceSize, length <= resourceSize - relative else { throw Failure.invalid }
            return try reader.read(fileOffset(resourceRVA + relative, length), length)
        }
        func entries(_ relative: Int) throws -> [(id: Int, offset: Int, directory: Bool)] {
            let header = try resource(relative, 16)
            let count = try u16(header, 12) + u16(header, 14)
            guard count <= 4096 else { throw Failure.invalid }
            let data = try resource(relative + 16, count * 8)
            return try (0..<count).map { index in
                let id = try u32(data, index * 8), value = try u32(data, index * 8 + 4)
                return (id, value & 0x7fffffff, value & 0x80000000 != 0)
            }
        }
        func leaves(_ type: Int) throws -> [(id: Int, language: Int, rva: Int, size: Int)] {
            guard let entry = try entries(0).first(where: { $0.id == type && $0.directory }) else { return [] }
            var result: [(Int, Int, Int, Int)] = []
            for name in try entries(entry.offset) where name.directory {
                for language in try entries(name.offset) where !language.directory {
                    guard result.count < 4096 else { throw Failure.invalid }
                    let data = try resource(language.offset, 16)
                    result.append((name.id, language.id, try u32(data, 0), try u32(data, 4)))
                }
            }
            return result
        }
        let groups = try leaves(14), icons = try leaves(3)
        for group in groups.prefix(32) {
            guard group.size >= 6, group.size <= 6 + 64 * 14 else { continue }
            let data = try reader.read(fileOffset(group.rva, group.size), group.size)
            guard try u16(data, 0) == 0, try u16(data, 2) == 1 else { continue }
            let count = try u16(data, 4)
            guard count > 0, count <= 64, data.count >= 6 + count * 14 else { continue }
            var candidates: [(width: Int, ico: Data, payload: Data)] = []
            for index in 0..<count {
                let base = 6 + index * 14, id = try u16(data, base + 12)
                let variants = icons.filter { $0.id == id }
                guard let icon = variants.first(where: { $0.language == group.language }) ?? variants.first,
                      icon.size > 0, icon.size <= 2 * 1024 * 1024,
                      icon.size == (try u32(data, base + 8)) else { continue }
                let payload = try reader.read(fileOffset(icon.rva, icon.size), icon.size)
                var ico = Data([0, 0, 1, 0, 1, 0])
                ico.append(data.subdata(in: base..<(base + 8)))
                append32(payload.count, to: &ico); append32(22, to: &ico); ico.append(payload)
                let width = data[base] == 0 ? 256 : Int(data[base])
                candidates.append((width, ico, payload))
            }
            for candidate in candidates.sorted(by: { $0.0 > $1.0 }) {
                let image = candidate.payload.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
                    ? decode(candidate.payload) : (decodeDIB(candidate.payload) ?? decode(candidate.ico))
                if let image, reader.unchanged() { return image }
            }
        }
        throw Failure.invalid
    }

    /// ImageIO's ICO reader rejects some valid small images. Decode common
    /// uncompressed RGB DIBs directly, including the legacy AND transparency
    /// mask; other DIB encodings still use the bounded ImageIO ICO decoder.
    private static func decodeDIB(_ data: Data) -> CGImage? {
        guard let header = try? u32(data, 0), header >= 40, header <= 124, data.count >= header,
              let width = try? u32(data, 4), let doubledHeight = try? u32(data, 8),
              width > 0, width <= 256, doubledHeight > 0, doubledHeight <= 512, doubledHeight % 2 == 0,
              (try? u16(data, 12)) == 1, (try? u32(data, 16)) == 0,
              let bits = try? u16(data, 14), bits == 24 || bits == 32 else { return nil }
        let height = doubledHeight / 2, stride = ((width * bits + 31) / 32) * 4
        let maskStride = ((width + 31) / 32) * 4, maskOffset = header + stride * height
        guard data.count >= maskOffset + maskStride * height else { return nil }
        let hasAlpha = bits == 32 && (0..<height).contains { y in
            (0..<width).contains { x in data[header + y * stride + x * 4 + 3] != 0 }
        }
        var rgba = Data(count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let row = height - 1 - y, source = header + row * stride + x * (bits / 8), dest = (y * width + x) * 4
                let transparent = data[maskOffset + row * maskStride + x / 8] & (0x80 >> (x % 8)) != 0
                rgba[dest] = data[source + 2]; rgba[dest + 1] = data[source + 1]; rgba[dest + 2] = data[source]
                rgba[dest + 3] = transparent ? 0 : (hasAlpha ? data[source + 3] : 255)
            }
        }
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func decode(_ data: Data) -> CGImage? {
        guard data.count <= 4 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 1024, height <= 1024 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
