import Foundation

public enum LabError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct Atom: Codable, Identifiable, Sendable {
    public var id: UInt64 { offset }
    public let type: String
    public let offset: UInt64
    public let size: UInt64
    public let headerSize: UInt64
    public let depth: Int
    public let path: String
    public var payload: UInt64 { offset + headerSize }
}

public struct TrackReport: Codable, Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    public var kind = "unknown"
    public var codec = "unknown"
    public var timescale: UInt64 = 0
    public var mediaDuration: UInt64 = 0
    public var headerDuration: UInt64 = 0
    public var headerDurationKnown = false
    public var sampleCount: UInt64?
    public var timingSampleCount: UInt64?
    public var timingDuration: UInt64?
    public var compositionSampleCount: UInt64?
    public var seconds: Double? {
        guard timescale > 0, mediaDuration != UInt64.max else { return nil }
        return Double(mediaDuration) / Double(timescale)
    }
    public var averageFPS: Double? {
        guard kind == "vide", let count = timingSampleCount,
              let ticks = timingDuration, ticks > 0, timescale > 0 else { return nil }
        return Double(count) * Double(timescale) / Double(ticks)
    }
}

public struct MP4Report: Codable, Sendable {
    public let fileName: String
    public let fileSize: UInt64
    public var atoms: [Atom] = []
    public var tracks: [TrackReport] = []
    public var warnings: [String] = []
    public var movieTimescale: UInt64 = 0
    public var movieDuration: UInt64 = 0
    public var movieDurationUnknown = false
    public var fragmented = false
    public var trailingUnparsedBytes: UInt64 = 0
    public var seconds: Double? {
        guard movieTimescale > 0, !movieDurationUnknown else { return nil }
        return Double(movieDuration) / Double(movieTimescale)
    }
    public var fastStart: Bool? {
        guard let moov = atoms.first(where: { $0.depth == 0 && $0.type == "moov" }),
              let mdat = atoms.first(where: { $0.depth == 0 && $0.type == "mdat" }) else { return nil }
        return moov.offset < mdat.offset
    }
    public var topLevelOrder: String {
        atoms.filter { $0.depth == 0 }.map(\.type).joined(separator: " → ")
    }
}

// Seek over media data; only read headers and bounded timing-table blocks.
// No frame decoding and no whole-video allocation.
public final class MP4Inspector {
    private let file: FileHandle
    private let fileSize: UInt64
    private let fileName: String
    private var atoms: [Atom] = []
    private var trailingUnparsedBytes: UInt64 = 0
    private let maxAtoms = 20_000
    private let maxEntries: UInt64 = 2_000_000
    private let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "mvex", "moof", "traf", "udta"]

    public init(url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        fileSize = try file.seekToEnd()
        fileName = url.lastPathComponent
    }
    deinit { try? file.close() }

    private func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else {
            throw LabError.invalid("قراءة تتجاوز حدود الملف")
        }
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: count), data.count == count else {
            throw LabError.invalid("الملف غير مكتمل")
        }
        return data
    }
    private func uint(_ offset: UInt64, _ width: Int = 4) throws -> UInt64 {
        try read(offset, width).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    private func fourCC(_ offset: UInt64) throws -> String {
        String(decoding: try read(offset, 4), as: UTF8.self)
    }
    private func require(_ atom: Atom, bytes: UInt64) throws {
        guard atom.size - atom.headerSize >= bytes else {
            throw LabError.invalid("جدول \(atom.type) أقصر من المطلوب")
        }
    }
    private func walk(_ start: UInt64, _ end: UInt64, _ depth: Int, _ parent: String) throws {
        guard depth <= 16 else { throw LabError.invalid("بنية MP4 أعمق من الحد المسموح") }
        var cursor = start
        while cursor < end {
            if end - cursor < 8 {
                if depth == 0 && atoms.contains(where: { $0.path == "moov" }) && atoms.contains(where: { $0.path == "mdat" }) {
                    trailingUnparsedBytes = end - cursor
                    return
                }
                throw LabError.invalid("رأس atom غير مكتمل عند \(cursor)")
            }
            var size = try uint(cursor)
            let type = try fourCC(cursor + 4)
            var header: UInt64 = 8
            if size == 1 {
                guard end - cursor >= 16 else { throw LabError.invalid("رأس 64-bit غير مكتمل") }
                size = try uint(cursor + 8, 8)
                header = 16
            } else if size == 0 { size = end - cursor }
            if type == "uuid" { header += 16 }
            guard atoms.count < maxAtoms else { throw LabError.invalid("تجاوز حد عدد atoms") }
            if size < header || size > end - cursor {
                if depth == 0 && atoms.contains(where: { $0.path == "moov" }) && atoms.contains(where: { $0.path == "mdat" }) {
                    trailingUnparsedBytes = end - cursor
                    return
                }
                throw LabError.invalid("حجم atom غير صالح عند \(cursor)")
            }
            let path = parent.isEmpty ? type : parent + "/" + type
            let atom = Atom(type: type, offset: cursor, size: size, headerSize: header, depth: depth, path: path)
            atoms.append(atom)
            if containers.contains(type) { try walk(atom.payload, cursor + size, depth + 1, path) }
            cursor += size
        }
    }

    private func duration(_ atom: Atom, trackHeader: Bool = false) throws -> (scale: UInt64, ticks: UInt64, unknown: Bool) {
        try require(atom, bytes: 4)
        let version = try uint(atom.payload, 1)
        guard version <= 1 else { throw LabError.invalid("إصدار \(atom.type) غير مدعوم") }
        let width = version == 1 ? 8 : 4
        let scaleOffset: UInt64 = version == 1 ? 20 : 12
        let ticksOffset: UInt64 = trackHeader ? (version == 1 ? 28 : 20) : scaleOffset + 4
        try require(atom, bytes: ticksOffset + UInt64(width))
        let scale: UInt64
        if trackHeader { scale = 0 } else { scale = try uint(atom.payload + scaleOffset) }
        let ticks = try uint(atom.payload + ticksOffset, width)
        return (scale, ticks, ticks == (width == 8 ? UInt64.max : UInt64(UInt32.max)))
    }

    private func tableTotals(_ atom: Atom, composition: Bool = false) throws -> (UInt64, UInt64) {
        try require(atom, bytes: 8)
        let count = try uint(atom.payload + 4)
        guard count <= maxEntries, count <= (atom.size - atom.headerSize - 8) / 8 else {
            throw LabError.invalid("عدد عناصر \(atom.type) أكبر من بيانات الجدول أو حد الفحص")
        }
        var samples: UInt64 = 0
        var ticks: UInt64 = 0
        var processed: UInt64 = 0
        while processed < count {
            let batch = min(UInt64(4096), count - processed)
            let bytes = try read(atom.payload + 8 + processed * 8, Int(batch * 8))
            for i in stride(from: 0, to: bytes.count, by: 8) {
                let n = bytes[i..<(i + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let delta = bytes[(i + 4)..<(i + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let (sum, overflow) = samples.addingReportingOverflow(n)
                guard !overflow else { throw LabError.invalid("تجاوز حساب عدد العينات") }
                samples = sum
                if !composition {
                    let (product, multiplyOverflow) = n.multipliedReportingOverflow(by: delta)
                    let (total, addOverflow) = ticks.addingReportingOverflow(product)
                    guard !multiplyOverflow, !addOverflow else { throw LabError.invalid("تجاوز حساب المدة") }
                    ticks = total
                }
            }
            processed += batch
        }
        return (samples, ticks)
    }

    public func inspect() throws -> MP4Report {
        atoms = []
        trailingUnparsedBytes = 0
        guard fileSize >= 8 else { throw LabError.invalid("الملف صغير أو غير صالح") }
        try walk(0, fileSize, 0, "")
        guard atoms.contains(where: { $0.type == "moov" && $0.depth == 0 }) else {
            throw LabError.invalid("لا توجد moov؛ هذا ليس MP4/MOV مكتملًا يدعمه الفاحص")
        }
        var report = MP4Report(fileName: fileName, fileSize: fileSize)
        report.atoms = atoms
        report.trailingUnparsedBytes = trailingUnparsedBytes
        if trailingUnparsedBytes > 0 {
            report.warnings.append("فحص جزئي: توجد \(trailingUnparsedBytes) بايت إضافية بعد atoms صالحة لا يمكن تفسيرها. البصمة تغطي mdat المعلن فقط.")
        }
        report.fragmented = atoms.contains { $0.type == "moof" || $0.type == "mvex" }
        if report.fragmented { report.warnings.append("ملف fragmented؛ جداول moov لا تمثل كل العينات. فحص المقاطع غير متاح في V1.") }
        if let mvhd = atoms.first(where: { $0.path == "moov/mvhd" }) {
            let d = try duration(mvhd)
            report.movieTimescale = d.scale
            report.movieDuration = d.ticks
            report.movieDurationUnknown = d.unknown
            if d.unknown || d.ticks == 0 { report.warnings.append("مدة mvhd صفر أو غير معرّفة؛ قد تظهر 0:00 في بعض المشغلات.") }
            if d.scale == 0 { report.warnings.append("movie timescale يساوي صفر.") }
        } else { report.warnings.append("رأس mvhd مفقود.") }
        let tracks = atoms.filter { $0.path == "moov/trak" }
        for (index, trak) in tracks.enumerated() {
            let children = atoms.filter { $0.offset > trak.offset && $0.offset < trak.offset + trak.size }
            var track = TrackReport(index: index + 1)
            if let hdlr = children.first(where: { $0.type == "hdlr" }) {
                try require(hdlr, bytes: 12)
                track.kind = try fourCC(hdlr.payload + 8)
            }
            if let tkhd = children.first(where: { $0.type == "tkhd" }) {
                let d = try duration(tkhd, trackHeader: true)
                track.headerDuration = d.ticks
                track.headerDurationKnown = !d.unknown && d.ticks > 0
            }
            if let mdhd = children.first(where: { $0.type == "mdhd" }) {
                let d = try duration(mdhd)
                track.timescale = d.scale
                track.mediaDuration = d.unknown ? UInt64.max : d.ticks
            }
            if let stsd = children.first(where: { $0.type == "stsd" }) {
                try require(stsd, bytes: 8)
                if try uint(stsd.payload + 4) > 0 {
                    try require(stsd, bytes: 16)
                    track.codec = try fourCC(stsd.payload + 12)
                }
            }
            if let stsz = children.first(where: { $0.type == "stsz" }) {
                try require(stsz, bytes: 12)
                let fixed = try uint(stsz.payload + 4)
                let count = try uint(stsz.payload + 8)
                if fixed == 0 && count > (stsz.size - stsz.headerSize - 12) / 4 {
                    throw LabError.invalid("stsz يحتوي عينات وهمية خارج حدود الجدول")
                }
                track.sampleCount = count
            } else if let stz2 = children.first(where: { $0.type == "stz2" }) {
                try require(stz2, bytes: 12)
                let field = try uint(stz2.payload + 7, 1)
                let count = try uint(stz2.payload + 8)
                guard [UInt64(4), 8, 16].contains(field),
                      (count * field + 7) / 8 <= stz2.size - stz2.headerSize - 12 else {
                    throw LabError.invalid("جدول stz2 غير صالح")
                }
                track.sampleCount = count
            }
            if let stts = children.first(where: { $0.type == "stts" }) {
                let (count, ticks) = try tableTotals(stts)
                track.timingSampleCount = count
                track.timingDuration = ticks
            }
            if let ctts = children.first(where: { $0.type == "ctts" }) {
                track.compositionSampleCount = try tableTotals(ctts, composition: true).0
            }
            if !report.fragmented {
                if let n = track.sampleCount, let t = track.timingSampleCount, n != t {
                    report.warnings.append("المسار \(track.index): stsz/stz2 = \(n)، stts = \(t)؛ عدد العينات غير متطابق.")
                }
                if let n = track.sampleCount, let c = track.compositionSampleCount, n != c {
                    report.warnings.append("المسار \(track.index): ctts لا يغطي نفس عدد العينات.")
                }
                if let ticks = track.timingDuration, track.mediaDuration != UInt64.max, ticks != track.mediaDuration {
                    report.warnings.append("المسار \(track.index): مدة stts تختلف عن mdhd.")
                }
                if track.sampleCount == nil || track.timingSampleCount == nil {
                    report.warnings.append("المسار \(track.index): جدول العينات أو التوقيت مفقود.")
                }
            }
            report.tracks.append(track)
        }
        if report.fastStart == false { report.warnings.append("moov بعد mdat؛ قد يؤخر هذا بدء التشغيل عبر الشبكة.") }
        if tracks.isEmpty { report.warnings.append("لا توجد مسارات داخل moov.") }
        return report
    }
}
