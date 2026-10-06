import Foundation

public enum LocalFileImport {
    /// The document picker has already materialized the provider's file with
    /// asCopy=true. Copy owned bytes; never coordinate a second provider read.
    public static func copy(from source: URL, to destination: URL,
                            progress: @Sendable (Double) -> Void = { _ in }) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw LabError.invalid("مسار النسخة يجب أن يختلف عن الفيديو الأصلي")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        guard length > 0 else { throw LabError.invalid("الفيديو فارغ. تأكد أن تنزيله من iCloud اكتمل.") }
        try input.seek(toOffset: 0)
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LabError.invalid("الملف الهدف موجود بالفعل")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw LabError.invalid("تعذر إنشاء نسخة محلية. تحقق من مساحة الجهاز.")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: UInt64 = 0
        var lastPercent = -1
        while copied < length {
            try Task.checkCancellation()
            let requested = Int(min(UInt64(1_048_576), length - copied))
            guard let chunk = try input.read(upToCount: requested), chunk.count == requested else {
                throw LabError.invalid("لم تكتمل قراءة الفيديو")
            }
            try output.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
            let percent = Int(copied * 100 / length)
            if percent != lastPercent { progress(Double(copied) / Double(length)); lastPercent = percent }
        }
        try Task.checkCancellation()
        try output.synchronize()
        completed = true
    }
}
