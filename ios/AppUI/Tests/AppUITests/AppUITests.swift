import XCTest
@testable import AppUI

final class AppUITests: XCTestCase {
    func testPasteAcceptsPermittedTextAndRejectsControlsAndOversize() throws {
        XCTAssertEqual(try PasteInput.utf8("hello\n\t"), Data("hello\n\t".utf8))
        XCTAssertThrowsError(try PasteInput.utf8("a\u{03}")) { XCTAssertEqual($0 as? PasteError, .unsupportedControl) }
        XCTAssertThrowsError(try PasteInput.utf8(String(repeating: "é", count: 30_001))) { XCTAssertEqual($0 as? PasteError, .tooLarge) }
    }

    func testInputModelDefersMarkedTextAndEmitsCommittedReplacementAndDeletion() throws {
        var model = TerminalInputModel()
        XCTAssertNil(try model.synchronize(text: "に", hasMarkedText: true))
        XCTAssertEqual(try model.synchronize(text: "日", hasMarkedText: false), Data("日".utf8))
        XCTAssertEqual(try model.synchronize(text: "日本", hasMarkedText: false), Data("本".utf8))
        XCTAssertEqual(try model.synchronize(text: "日", hasMarkedText: false), Data([0x7f]))
        XCTAssertNil(try model.synchronize(text: "日", hasMarkedText: false))
    }

    func testFrameDecoderRejectsTruncatedCellAfterValidHeader() {
        var bytes = header()
        cell(&bytes, length: 1)
        XCTAssertThrowsError(try TerminalFrame.decode(bytes))
    }

    func testFrameDecoderRejectsNegativeAndOversizedCellLengths() {
        var negative = header(); cell(&negative, length: UInt32.max)
        XCTAssertThrowsError(try TerminalFrame.decode(negative))
        var oversized = header(); cell(&oversized, length: 1025)
        XCTAssertThrowsError(try TerminalFrame.decode(oversized))
    }

    func testFrameDecoderRejectsTrailingBytesAfterCompleteFrame() throws {
        var bytes = header()
        for _ in 0..<4 { cell(&bytes, length: 0) }
        bytes.append(0)
        XCTAssertThrowsError(try TerminalFrame.decode(bytes))
    }

    private func header() -> Data {
        var data = Data()
        [2, 2, 0, 0, 0, 1, 0xffe6edf3, 0xff10141c, 0xffe6edf3].forEach { append(UInt32($0), to: &data) }
        return data
    }

    private func cell(_ data: inout Data, length: UInt32) {
        append(1, to: &data); append(0, to: &data); append(0xffe6edf3, to: &data); append(0xff10141c, to: &data); append(length, to: &data)
    }

    private func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
