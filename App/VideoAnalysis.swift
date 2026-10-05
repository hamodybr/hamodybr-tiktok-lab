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
        if let fps = video?.nominalFPS, fps > 0 { return String(format: "%.3f", fps) }
        if let fps = mp4.tracks.first(where: { $0.kind == "vide" })?.averageFPS { return String(format: "%.3f (متوسط)", fps) }
        return "غير متاح"
    }
}

enum VideoAnalyzer {
    static func inspect(url: URL, label: String) async throws -> VideoAnalysis {
        let core = try await Task.detached(priority: .userInitiated) {
            let report = try MP4Inspector(url: url).inspect()
            let hash = try MediaFingerprint.sha256(url: url, report: report)
            return (report, hash)
        }.value
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var duration: Double?
        var tracks: [AppleTrackReport] = []
        var warnings: [String] = []
        do {
            let time = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite, seconds >= 0 { duration = seconds }
        } catch { warnings.append("AVFoundation لم يقرأ المدة: \(error.localizedDescription)") }
        do {
            for track in try await asset.loadTracks(withMediaType: .video) {
                do {
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let display = size.applying(transform)
                    let fps = try await track.load(.nominalFrameRate)
                    let rate = try await track.load(.estimatedDataRate)
                    var info = AppleTrackReport(kind: "video", width: Int(abs(display.width).rounded()), height: Int(abs(display.height).rounded()), nominalFPS: fps, estimatedBitrate: rate)
                    let formats = try await track.load(.formatDescriptions)
                    if let format = formats.first {
                        info.colorPrimaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
                        info.transferFunction = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                        info.ycbcrMatrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
                    }
                    tracks.append(info)
                } catch { warnings.append("تعذر تحميل خصائص أحد مسارات الفيديو: \(error.localizedDescription)") }
            }
            for track in try await asset.loadTracks(withMediaType: .audio) {
                do {
                    var info = AppleTrackReport(kind: "audio", estimatedBitrate: try await track.load(.estimatedDataRate))
                    let formats = try await track.load(.formatDescriptions)
                    if let format = formats.first,
                       let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                        info.sampleRate = audio.mSampleRate
                        info.channels = audio.mChannelsPerFrame
                    }
                    tracks.append(info)
                } catch { warnings.append("تعذر تحميل خصائص أحد مسارات الصوت: \(error.localizedDescription)") }
            }
        } catch { warnings.append("AVFoundation لم يقرأ المسارات: \(error.localizedDescription)") }
        if let apple = duration, let header = core.0.seconds, abs(apple - header) > 0.05 {
            warnings.append("مدة مشغل Apple تختلف عن mvhd بأكثر من 0.05 ثانية.")
        }
        return VideoAnalysis(mp4: core.0, mediaSHA256: core.1, appleDuration: duration, appleTracks: tracks, appleWarnings: warnings, analyzedAt: Date(), label: label)
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
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}
