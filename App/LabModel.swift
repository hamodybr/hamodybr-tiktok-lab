import SwiftUI
import PhotosUI

enum VideoSlot: String, CaseIterable, Identifiable {
    case original, tiktok
    var id: String { rawValue }
    var title: String { self == .original ? "الأصل" : "نسخة تيكتوك" }
}

private struct SavedSession: Codable {
    var original: VideoAnalysis?
    var tiktok: VideoAnalysis?
    var paths: [String: String]
    var selected: String? = nil
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
    @Published var progress: Double = 0
    @Published var selectedFileName: String?
    @Published private var preview: VideoAnalysis?
    @Published private(set) var activeURL: URL?
    private var importURLs: [VideoSlot: URL] = [:]
    private var job: UUID?
    private var work: Task<Void, Never>?
    private var lastFailure: String?
    private let root: URL

    var current: VideoAnalysis? { preview ?? (selected == .original ? original : tiktok) }
    var currentVideoURL: URL? { importURLs[selected] }
    var hasFailure: Bool { lastFailure != nil }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        root = support.appendingPathComponent("HAMODYBRLab", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-reset") { try? FileManager.default.removeItem(at: root) }
        #endif
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        restore()
        prepareSample()
    }

    func pickerOpened() {
        error = nil
        status = "اختر فيديو MP4 أو MOV؛ ملفات iCloud تُحمّل قبل الاستيراد"
    }
    func pickerCancelled() { status = "أُلغي اختيار الملف" }
    func beginFileImport(_ source: URL, slot: VideoSlot) {
        guard !busy else { return }
        let id = begin(slot: slot, fileName: source.lastPathComponent)
        // Acquire access synchronously in the picker callback, before hopping
        // to another task. asCopy URLs normally refer to an owned Inbox copy.
        let scoped = source.startAccessingSecurityScopedResource()
        work = Task {
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            await process(source, slot: slot, id: id)
        }
    }
    func beginPhotoImport(_ item: PhotosPickerItem, slot: VideoSlot) {
        guard !busy else { return }
        let id = begin(slot: slot, fileName: "فيديو من الصور")
        status = "جارٍ تحميل الفيديو من الصور"
        work = Task {
            var imported: URL?
            do {
                guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                    throw LabError.invalid("تعذر استيراد الفيديو من الصور")
                }
                imported = movie.url
                try Task.checkCancellation()
                await process(movie.url, slot: slot, id: id)
            } catch { fail(error, id: id) }
            if let imported { try? FileManager.default.removeItem(at: imported) }
        }
    }
    private func begin(slot: VideoSlot, fileName: String) -> UUID {
        let id = UUID()
        job = id
        busy = true
        progress = 0
        preview = nil
        selected = slot
        selectedFileName = fileName
        status = "تم اختيار \(fileName)؛ جارٍ الاستيراد"
        error = nil
        lastFailure = nil
        exportURL = nil
        return id
    }
    private func update(_ value: Double, _ message: String, id: UUID) {
        guard job == id else { return }
        progress = max(progress, min(1, value))
        status = message
    }
    private func process(_ source: URL, slot: VideoSlot, id: UUID) async {
        let folder = root.appendingPathComponent("Imports", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do {
            let copy = Task.detached(priority: .userInitiated) {
                try LocalFileImport.copy(from: source, to: destination) { value in
                    Task { @MainActor in self.update(value * 0.25, "نسخ الفيديو إلى التطبيق", id: id) }
                }
            }
            try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
            try Task.checkCancellation()
            let result = try await VideoAnalyzer.inspect(url: destination, label: slot.title, progress: { value, message in
                Task { @MainActor in self.update(0.25 + value * 0.75, message, id: id) }
            }, coreReady: { report in
                Task { @MainActor in if self.job == id { self.preview = report } }
            })
            try Task.checkCancellation()
            guard job == id else { throw CancellationError() }
            let previous = importURLs[slot]
            if slot == .original { original = result } else { tiktok = result }
            importURLs[slot] = destination
            activeURL = destination
            preview = nil
            progress = 1
            busy = false
            job = nil
            work = nil
            selectedFileName = result.mp4.fileName
            status = "اكتمل الفحص • \(result.warnings.count) ملاحظة"
            save()
            if let previous { try? FileManager.default.removeItem(at: previous.deletingLastPathComponent()) }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            fail(error, id: id)
        }
    }
    private func fail(_ failure: Error, id: UUID) {
        guard job == id else { return }
        preview = nil
        busy = false
        job = nil
        work = nil
        if failure is CancellationError { status = "أُلغي الفحص"; return }
        let ns = failure as NSError
        let message = failure.localizedDescription
        lastFailure = "\(message) [\(ns.domain):\(ns.code)]"
        error = message
        status = "تعذر استيراد أو فحص \(selectedFileName ?? "الفيديو")"
    }
    func cancel() {
        work?.cancel()
        work = nil
        job = nil
        busy = false
        preview = nil
        status = "أُلغي الفحص؛ تقدر تختار فيديو آخر"
    }
    func clearCurrent() {
        guard !busy else { return }
        if let url = importURLs.removeValue(forKey: selected) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        if selected == .original { original = nil } else { tiktok = nil }
        exportURL = nil
        selectedFileName = nil
        status = "اختر فيديو \(selected.title)"
        save()
    }
    func sample() {
        guard let source = Bundle.main.url(forResource: "Sample-60fps", withExtension: "mp4") else {
            error = "فيديو الاختبار غير موجود"; return
        }
        beginFileImport(source, slot: selected)
    }
    private func prepareSample() {
        guard let sample = Bundle.main.url(forResource: "Sample-60fps", withExtension: "mp4"),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let target = docs.appendingPathComponent("Sample-60fps.mp4")
        if !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.copyItem(at: sample, to: target) }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-reset") {
            try? Data().write(to: docs.appendingPathComponent("Empty-test.mp4"))
        }
        #endif
    }
    private func restore() {
        let path = root.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: path), let session = try? JSONDecoder().decode(SavedSession.self, from: data) else { return }
        for slot in VideoSlot.allCases {
            guard let relative = session.paths[slot.rawValue], !relative.contains(".."), relative.hasPrefix("Imports/") else { continue }
            let url = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) {
                importURLs[slot] = url
                if slot == .original { original = session.original } else { tiktok = session.tiktok }
            }
        }
        selected = VideoSlot(rawValue: session.selected ?? "") ?? (original == nil && tiktok != nil ? .tiktok : .original)
        if original != nil || tiktok != nil { status = "استُعيدت آخر مقارنة محفوظة" }
    }
    private func save() {
        let paths = Dictionary(uniqueKeysWithValues: importURLs.map { ($0.key.rawValue, $0.value.path.replacingOccurrences(of: root.path + "/", with: "")) })
        do {
            let data = try JSONEncoder().encode(SavedSession(original: original, tiktok: tiktok, paths: paths, selected: selected.rawValue))
            try data.write(to: root.appendingPathComponent("session.json"), options: .atomic)
        } catch { status += " • تعذر حفظ الجلسة" }
    }
    func export() {
        do {
            struct Session: Encodable {
                let app = "HAMODYBR TikTok Lab"
                let version = "0.2.0"
                let note = "Metadata comparison is not a visual-quality measurement. mdat hashes refer to all media payload bytes, including audio. Videos are not modified."
                var original: VideoAnalysis?
                var tiktok: VideoAnalysis?
                var lastImportFile: String?
                var importFailure: String?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Session(original: original, tiktok: tiktok, lastImportFile: selectedFileName, importFailure: lastFailure))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LabExports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("HAMODYBR-Lab-\(UUID().uuidString.prefix(8)).json")
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch { self.error = error.localizedDescription }
    }
}
