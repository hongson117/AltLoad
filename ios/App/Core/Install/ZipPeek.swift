import Compression
import Foundation

/// Unofficial fork: reads Payload/<App>.app/Info.plist out of an IPA without unzipping it all.
enum ZipPeek {
    static func appInfoPlist(in ipa: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: ipa, options: .alwaysMapped), data.count > 22 else { return nil }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

        // End of central directory record.
        var eocd = -1
        var i = data.count - 22
        let floor = max(0, data.count - 22 - 65_535)
        while i >= floor {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        guard p > 0, p < data.count else { return nil } // zip64 not handled; caller re-checks later

        for _ in 0..<count {
            guard p + 46 <= data.count, u32(p) == 0x0201_4b50 else { return nil }
            let method = u16(p + 10)
            let compSize = u32(p + 20)
            let size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            let parts = name.split(separator: "/")
            guard parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"), parts[2] == "Info.plist" else { continue }
            guard local + 30 <= data.count, u32(local) == 0x0403_4b50 else { return nil }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compSize <= data.count, size > 0, size < 16_000_000 else { return nil }
            let raw = data.subdata(in: start..<(start + compSize))
            let bytes: Data
            switch method {
            case 0: bytes = raw
            case 8:
                var out = Data(count: size)
                let n = out.withUnsafeMutableBytes { dst in
                    raw.withUnsafeBytes { src in
                        compression_decode_buffer(
                            dst.bindMemory(to: UInt8.self).baseAddress!, size,
                            src.bindMemory(to: UInt8.self).baseAddress!, compSize, nil, COMPRESSION_ZLIB)
                    }
                }
                guard n == size else { return nil }
                bytes = out
            default: return nil
            }
            return (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String: Any]
        }
        return nil
    }
}
