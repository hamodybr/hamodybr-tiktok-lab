import XCTest
@testable import LabCore

final class ImportReliabilityTests: XCTestCase {
    private func temporary() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    func testImportPreservesBytesAndSource() throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("فيديو ١.MP4")
        let target = dir.appendingPathComponent("owned/video.mp4")
        let data = Data(repeating: 71, count: 2_200_000)
        try data.write(to: source)
        try LocalFileImport.copy(from: source, to: target)
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertEqual(try Data(contentsOf: target), data)
    }
    func testEmptyFileFailsWithoutLeavingPartialCopy() throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("empty.mp4"), target = dir.appendingPathComponent("target.mp4")
        try Data().write(to: source)
        XCTAssertThrowsError(try LocalFileImport.copy(from: source, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testImportNeverOverwritesExistingDestination() throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("original.mp4"), target = dir.appendingPathComponent("existing.mp4")
        try Data([1, 2]).write(to: source)
        try Data([3, 4]).write(to: target)
        XCTAssertThrowsError(try LocalFileImport.copy(from: source, to: target))
        XCTAssertEqual(try Data(contentsOf: target), Data([3, 4]))
        XCTAssertThrowsError(try LocalFileImport.copy(from: source, to: source))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2]))
    }
    func testCancelledImportDoesNotWriteTarget() async throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("original.mp4"), target = dir.appendingPathComponent("target.mp4")
        try Data([1, 2]).write(to: source)
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try LocalFileImport.copy(from: source, to: target)
        }
        do { try await worker.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testDeadlineReturnsSuccessfulValue() async throws {
        let value = try await AsyncDeadline.run(seconds: 1) { 123 }
        XCTAssertEqual(value, 123)
    }
    func testDeadlineCannotHangOnUncooperativeReader() async throws {
        let start = Date()
        do {
            let _: Int = try await AsyncDeadline.run(seconds: 0.02) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { continuation.resume(returning: 4) }
                }
            }
            XCTFail("Expected deadline expiration")
        } catch { XCTAssertTrue(error is DeadlineError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
    }
    func testDeadlinePropagatesReaderFailure() async {
        do {
            let _: Int = try await AsyncDeadline.run(seconds: 1) { throw LabError.invalid("provider failed") }
            XCTFail("Expected reader error")
        } catch { XCTAssertEqual(error.localizedDescription, "provider failed") }
    }
    func testDeadlinePropagatesCancellation() async {
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AsyncDeadline.run(seconds: 1) { 1 }
        }
        do { _ = try await worker.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
