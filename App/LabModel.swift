import SwiftUI
import PhotosUI

enum VideoSlot: String, CaseIterable, Identifiable {
    case original, tiktok
    var id: String { rawValue }
    var title: String { self == .original ? "الأصل" : "نسخة تيكتوك" }
}

@MainActor
final class LabModel: ObservableObject {
    @Published var selected: VideoSlot = .original
    @Published var original: VideoAnalysis?
    @Published var tiktok: VideoAnalysis?
    @Published var busy = false
    @Published var status = "اختر الفيديو الأصلي لبدء الفحص"
    @Published var error: String?
    @Published var exportURL: URL?
    private var importURLs: [VideoSlot: URL] = [:]

    var current: VideoAnalysis? { selected == .original ? original : tiktok }

    func importFile(_ source: URL, slot: VideoSlot) async {
        guard !busy else { return }
        busy = true
        error = nil
        status = "جارٍ استيراد \(slot.title)…"
        defer { busy = false }
        var destination: URL?
        do {
            let copied = try await Task.detached(priority: .userInitiated) {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("LabImports", isDirectory: true)
                let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(source.lastPathComponent)
                do {
                    let coordinator = NSFileCoordinator()
                    var coordinationError: NSError?
                    var copyError: Error?
                    coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                        do { try FileManager.default.copyItem(at: readable, to: target) }
                        catch { copyError = error }
                    }
                    if let e = coordinationError { throw e }
                    if let e = copyError { throw e }
                    return target
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
            }.value
            destination = copied
            status = "جارٍ فحص البنية والتوقيت وحساب بصمة البيانات…"
            let result = try await VideoAnalyzer.inspect(url: copied, label: slot.title)
            if slot == .original { original = result } else { tiktok = result }
            if let previous = importURLs[slot] { try? FileManager.default.removeItem(at: previous.deletingLastPathComponent()) }
            importURLs[slot] = copied
            exportURL = nil
            selected = slot
            status = "اكتمل الفحص • \(result.warnings.count) ملاحظة"
        } catch {
            if let destination { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
            self.error = error.localizedDescription
            status = "تعذر الفحص؛ ملفك الأصلي محفوظ كما هو"
        }
    }

    func importPhoto(_ item: PhotosPickerItem, slot: VideoSlot) async {
        guard !busy else { return }
        busy = true
        status = "جارٍ تحميل الفيديو من الصور…"
        error = nil
        do {
            guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                throw LabError.invalid("تعذر استيراد الفيديو من الصور")
            }
            busy = false
            await importFile(movie.url, slot: slot)
            try? FileManager.default.removeItem(at: movie.url)
        } catch {
            busy = false
            self.error = error.localizedDescription
            status = "تعذر الاستيراد من الصور"
        }
    }

    func export() {
        do {
            struct Session: Encodable {
                let app = "HAMODYBR TikTok Lab"
                let version = "0.1.0"
                let note = "Metadata comparison is not a visual-quality measurement. mdat hashes refer to all media payload bytes, including audio. V1 does not modify or upload videos."
                var original: VideoAnalysis?
                var tiktok: VideoAnalysis?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Session(original: original, tiktok: tiktok))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LabExports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("HAMODYBR-Lab-\(UUID().uuidString.prefix(8)).json")
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch { self.error = error.localizedDescription }
    }
}
