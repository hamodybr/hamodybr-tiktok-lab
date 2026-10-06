import Foundation
import CryptoKit

public enum MediaFingerprint {
    /// Hash only mdat payloads, in file order. Equal values prove these payload
    /// bytes are unchanged; unequal values are NOT a visual-quality score.
    public static func sha256(url: URL, report: MP4Report,
                              progress: @Sendable (Double) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        let media = report.atoms.filter { $0.depth == 0 && $0.type == "mdat" }
        guard !media.isEmpty else { throw LabError.invalid("لا توجد بيانات mdat لحساب البصمة") }
        let total = media.reduce(UInt64(0)) { $0 + $1.size - $1.headerSize }
        var processed: UInt64 = 0
        var lastPercent = -1
        for atom in media {
            try handle.seek(toOffset: atom.payload)
            var remaining = atom.size - atom.headerSize
            while remaining > 0 {
                try Task.checkCancellation()
                let length = Int(min(UInt64(1_048_576), remaining))
                guard let bytes = try handle.read(upToCount: length), bytes.count == length else {
                    throw LabError.invalid("بيانات mdat غير مكتملة")
                }
                hash.update(data: bytes)
                remaining -= UInt64(length)
                processed += UInt64(length)
                if total > 0 {
                    let percent = Int(processed * 100 / total)
                    if percent != lastPercent { progress(Double(processed) / Double(total)); lastPercent = percent }
                }
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
