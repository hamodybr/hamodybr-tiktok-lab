import Foundation
import CryptoKit

public enum MediaFingerprint {
    /// Hash only mdat payloads, in file order. Equal values prove these payload
    /// bytes are unchanged; unequal values are NOT a visual-quality score.
    public static func sha256(url: URL, report: MP4Report) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        let media = report.atoms.filter { $0.depth == 0 && $0.type == "mdat" }
        guard !media.isEmpty else { throw LabError.invalid("لا توجد بيانات mdat لحساب البصمة") }
        for atom in media {
            try handle.seek(toOffset: atom.payload)
            var remaining = atom.size - atom.headerSize
            while remaining > 0 {
                let length = Int(min(UInt64(1_048_576), remaining))
                guard let bytes = try handle.read(upToCount: length), bytes.count == length else {
                    throw LabError.invalid("بيانات mdat غير مكتملة")
                }
                hash.update(data: bytes)
                remaining -= UInt64(length)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
