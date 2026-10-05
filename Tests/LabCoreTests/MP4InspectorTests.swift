import XCTest
@testable import LabCore

final class MP4InspectorTests: XCTestCase {
    private func be(_ n: UInt64, _ width: Int = 4) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) })
    }
    private func atom(_ type: String, _ payload: Data) -> Data {
        be(UInt64(payload.count + 8)) + Data(type.utf8) + payload
    }
    private func movie(duration: UInt64 = 1200, timingCount: UInt64 = 60,
                       sampleCount: UInt64 = 60, compositionCount: UInt64? = nil,
                       fastStart: Bool = true, version: UInt8 = 0,
                       truncatedSizes: Bool = false, fragmented: Bool = false) -> Data {
        let header: Data
        if version == 1 {
            header = Data([1, 0, 0, 0]) + Data(repeating: 0, count: 16) + be(600) + be(duration, 8)
        } else {
            header = Data(repeating: 0, count: 12) + be(600) + be(duration)
        }
        let mdhd = atom("mdhd", Data(repeating: 0, count: 12) + be(600) + be(1200))
        let tkhd = atom("tkhd", Data(repeating: 0, count: 20) + be(1200))
        let hdlr = atom("hdlr", Data(repeating: 0, count: 8) + Data("vide".utf8))
        let stsd = atom("stsd", be(0) + be(1) + be(8) + Data("avc1".utf8))
        let stts = atom("stts", be(0) + be(1) + be(timingCount) + be(20))
        let stsz = atom("stsz", be(0) + be(truncatedSizes ? 0 : 1) + be(sampleCount))
        var table = stsd + stts + stsz
        if let count = compositionCount { table += atom("ctts", be(0) + be(1) + be(count) + be(0)) }
        let trak = atom("trak", tkhd + atom("mdia", mdhd + hdlr + atom("minf", atom("stbl", table))))
        var moovData = atom("mvhd", header) + trak
        if fragmented { moovData += atom("mvex", Data()) }
        let moov = atom("moov", moovData)
        let mdat = atom("mdat", Data(repeating: 42, count: 60))
        let ftyp = atom("ftyp", Data("isom".utf8) + be(0) + Data("isom".utf8))
        return ftyp + (fastStart ? moov + mdat : mdat + moov)
    }
    private func withFile<T>(_ data: Data, body: (URL) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }
    private func inspect(_ data: Data) throws -> MP4Report {
        try withFile(data) { try MP4Inspector(url: $0).inspect() }
    }
    func testValidTimingAndCodec() throws {
        let r = try inspect(movie())
        XCTAssertEqual(r.seconds, 2)
        XCTAssertEqual(r.tracks.first?.averageFPS, 30)
        XCTAssertEqual(r.tracks.first?.sampleCount, 60)
        XCTAssertEqual(r.tracks.first?.codec, "avc1")
        XCTAssertEqual(r.fastStart, true)
        XCTAssertTrue(r.warnings.isEmpty)
    }
    func testZeroMovieDurationDetected() throws {
        let r = try inspect(movie(duration: 0))
        XCTAssertEqual(r.seconds, 0)
        XCTAssertTrue(r.warnings.contains { $0.contains("0:00") })
    }
    func testUnknown32And64BitDurations() throws {
        let r32 = try inspect(movie(duration: UInt64(UInt32.max)))
        let r64 = try inspect(movie(duration: UInt64.max, version: 1))
        XCTAssertNil(r32.seconds)
        XCTAssertNil(r64.seconds)
        XCTAssertTrue(r32.movieDurationUnknown)
        XCTAssertTrue(r64.movieDurationUnknown)
    }
    func testVersionOneDuration() throws {
        XCTAssertEqual(try inspect(movie(version: 1)).seconds, 2)
    }
    func testPhantomTimingSamplesDetected() throws {
        let r = try inspect(movie(timingCount: 5455))
        XCTAssertTrue(r.warnings.contains { $0.contains("غير متطابق") })
        XCTAssertTrue(r.warnings.contains { $0.contains("mdhd") })
    }
    func testCompositionCountMismatch() throws {
        let r = try inspect(movie(compositionCount: 61))
        XCTAssertTrue(r.warnings.contains { $0.contains("ctts") })
    }
    func testTruncatedSampleSizesRejects() {
        XCTAssertThrowsError(try inspect(movie(truncatedSizes: true)))
    }
    func testMoovAfterMediaDetected() throws {
        let r = try inspect(movie(fastStart: false))
        XCTAssertEqual(r.fastStart, false)
        XCTAssertTrue(r.warnings.contains { $0.contains("moov بعد") })
    }
    func testFragmentedDoesNotTreatEmptyMoovTablesAsComplete() throws {
        let r = try inspect(movie(timingCount: 1, fragmented: true))
        XCTAssertTrue(r.fragmented)
        XCTAssertTrue(r.warnings.contains { $0.contains("fragmented") })
        XCTAssertFalse(r.warnings.contains { $0.contains("غير متطابق") })
    }
    func testMalformedAtomRejects() {
        XCTAssertThrowsError(try inspect(be(UInt64.max, 8) + Data("moov".utf8)))
        XCTAssertThrowsError(try inspect(Data([0, 0, 0])))
        XCTAssertThrowsError(try inspect(atom("ftyp", Data("isom".utf8))))
    }
    func testExtendedSizeAndZeroSizeAtoms() throws {
        let extended = be(1) + Data("free".utf8) + be(20, 8) + Data(repeating: 0, count: 4)
        let end = be(0) + Data("free".utf8) + Data(repeating: 0, count: 4)
        let r = try inspect(extended + movie() + end)
        XCTAssertEqual(r.atoms.first?.headerSize, 16)
        XCTAssertEqual(r.atoms.last?.size, 12)
    }
    func testTrailingGarbageProducesPartialReport() throws {
        let r = try inspect(movie() + be(4) + Data(repeating: 0, count: 8))
        XCTAssertEqual(r.trailingUnparsedBytes, 12)
        XCTAssertEqual(r.tracks.first?.sampleCount, 60)
        XCTAssertTrue(r.warnings.contains { $0.contains("فحص جزئي") })
    }
    func testMediaFingerprintIgnoresHeaderChange() throws {
        let first = try withFile(movie()) { url in
            try MediaFingerprint.sha256(url: url, report: MP4Inspector(url: url).inspect())
        }
        let zeroDuration = try withFile(movie(duration: 0)) { url in
            try MediaFingerprint.sha256(url: url, report: MP4Inspector(url: url).inspect())
        }
        var changed = movie()
        changed[changed.count - 1] = 43
        let modified = try withFile(changed) { url in
            try MediaFingerprint.sha256(url: url, report: MP4Inspector(url: url).inspect())
        }
        XCTAssertEqual(first, zeroDuration)
        XCTAssertNotEqual(first, modified)
    }

    func testGeneratedRealWorldFixtureIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["LAB_FIXTURE"] else { throw XCTSkip("No external media fixture provided") }
        let r = try MP4Inspector(url: URL(fileURLWithPath: path)).inspect()
        XCTAssertEqual(r.tracks.filter { $0.kind == "vide" }.count, 1)
        XCTAssertEqual(r.tracks.filter { $0.kind == "soun" }.count, 1)
        XCTAssertTrue(r.warnings.isEmpty, r.warnings.joined(separator: "\n"))
        XCTAssertEqual(r.tracks.first(where: { $0.kind == "vide" })?.averageFPS ?? 0, 60, accuracy: 0.001)
    }
}
