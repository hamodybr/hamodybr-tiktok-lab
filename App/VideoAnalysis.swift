import Foundation
import AVFoundation
import CoreMedia
import CoreTransferable
import UniformTypeIdentifiers

struct AppleTrackReport: Codable, Sendable {
    var kind: String
    var width: Int?
    var height: Int?
    var nominalFPS: Float?
    var estimatedBitrate: Float?
    var sampleRate: Double?
    var channels: UInt32?
    var colorPrimaries: String?
    var transferFunction: String?
    var ycbcrMatrix: String?
}

struct VideoAnalysis: Codable, Sendable {
    var mp4: MP4Report
    var mediaSHA256: String
    var appleDuration: Double?
    var appleTracks: [AppleTrackReport]
    var appleWarnings: [String]
    var analyzedAt: Date
    var label: String
    var video: AppleTrackReport? { appleTracks.first { $0.kind == "video" } }
    var audio: AppleTrackReport? { appleTracks.first { $0.kind == "audio" } }
    var duration: Double? { appleDuration ?? mp4.seconds }
    var warnings: [String] { mp4.warnings + appleWarnings }
    var resolution: String {
        guard let v = video, let w = v.width, let h = v.height else { return "غير متاح" }
        return "\(w) × \(h)"
    }
    var fpsText: String {
        if let fps = video?.nominalFPS, fps > 0, fps.isFinite { return String(format: "%.3f", fps) }
        if let fps = mp4.tracks.first(where: { $0.kind == "vide" })?.averageFPS { return String(format: "%.3f (متوسط)", fps) }
        return "غير متاح"
    }
}

private struct AppleProbe: Sendable {
    var duration: Double?
    var tracks: [AppleTrackReport]
    var warnings: [String]
}

private final class AssetBox: @unchecked Sendable {
    let asset: AVURLAsset
    init(url: URL) { asset = AVURLAsset(url: url) }
}

enum VideoAnalyzer {
    static func inspect(url: URL, label: String,
                        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in },
                        coreReady: @escaping @Sendable (VideoAnalysis) -> Void = { _ in }) async throws -> VideoAnalysis {
        progress(0.05, "فحص بنية الفيديو والتوقيت")
        let worker = Task.detached(priority: .userInitiated) {
            let report = try MP4Inspector(url: url).inspect()
            progress(0.12, "حساب بصمة بيانات الفيديو والصوت")
            let hash = try MediaFingerprint.sha256(url: url, report: report) { value in
                progress(0.12 + value * 0.73, "حساب بصمة بيانات الفيديو والصوت")
            }
            return (report, hash)
        }
        let core = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        var result = VideoAnalysis(mp4: core.0, mediaSHA256: core.1, appleDuration: nil,
                                   appleTracks: [], appleWarnings: [], analyzedAt: Date(), label: label)
        coreReady(result)
        progress(0.9, "قراءة معلومات مشغّل Apple")
        let box = AssetBox(url: url)
        do {
            let probe = try await AsyncDeadline.run(seconds: 7, onCancel: { box.asset.cancelLoading() }) {
                await probeApple(box.asset)
            }
            result.appleDuration = probe.duration
            result.appleTracks = probe.tracks
            result.appleWarnings = probe.warnings
        } catch is CancellationError { throw CancellationError() }
        catch {
            result.appleWarnings.append("اكتمل فحص MP4؛ تعذرت قراءة معلومات مشغّل Apple خلال الوقت المحدد.")
        }
        if let apple = result.appleDuration, let header = core.0.seconds, abs(apple - header) > 0.05 {
            result.appleWarnings.append("مدة مشغل Apple تختلف عن mvhd بأكثر من 0.05 ثانية.")
        }
        progress(1, "اكتمل الفحص")
        return result
    }

    private static func probeApple(_ asset: AVURLAsset) async -> AppleProbe {
        var result = AppleProbe(tracks: [], warnings: [])
        do {
            let time = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite, seconds >= 0 { result.duration = seconds }
        } catch { result.warnings.append("AVFoundation لم يقرأ المدة: \(error.localizedDescription)") }
        do {
            for track in try await asset.loadTracks(withMediaType: .video) {
                try Task.checkCancellation()
                do {
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let display = size.applying(transform)
                    let fps = try await track.load(.nominalFrameRate)
                    let rate = try await track.load(.estimatedDataRate)
                    var info = AppleTrackReport(kind: "video")
                    if display.width.isFinite, display.height.isFinite,
                       abs(display.width) < 1_000_000, abs(display.height) < 1_000_000 {
                        info.width = Int(abs(display.width).rounded())
                        info.height = Int(abs(display.height).rounded())
                    }
                    if fps.isFinite { info.nominalFPS = fps }
                    if rate.isFinite { info.estimatedBitrate = rate }
                    let formats = try await track.load(.formatDescriptions)
                    if let format = formats.first {
                        info.colorPrimaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
                        info.transferFunction = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                        info.ycbcrMatrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
                    }
                    result.tracks.append(info)
                } catch { result.warnings.append("تعذر تحميل خصائص أحد مسارات الفيديو.") }
            }
            for track in try await asset.loadTracks(withMediaType: .audio) {
                try Task.checkCancellation()
                do {
                    var info = AppleTrackReport(kind: "audio")
                    let rate = try await track.load(.estimatedDataRate)
                    if rate.isFinite { info.estimatedBitrate = rate }
                    let formats = try await track.load(.formatDescriptions)
                    if let format = formats.first,
                       let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                        if audio.mSampleRate.isFinite { info.sampleRate = audio.mSampleRate }
                        info.channels = audio.mChannelsPerFrame
                    }
                    result.tracks.append(info)
                } catch { result.warnings.append("تعذر تحميل خصائص أحد مسارات الصوت.") }
            }
        } catch { result.warnings.append("AVFoundation لم يقرأ المسارات.") }
        return result
    }
}

struct ImportedMovie: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoImports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try LocalFileImport.copy(from: received.file, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}
