import Foundation

public struct TerminalCell: Equatable, Sendable {
    public let width: Int32, flags: UInt32, foreground: UInt32, background: UInt32, text: String
}
public struct TerminalFrame: Equatable, Sendable {
    public let columns: Int, rows: Int, cursorX: Int, cursorY: Int
    public let cursorStyle: UInt32, cursorFlags: UInt32, foreground: UInt32, background: UInt32, cursorColor: UInt32
    public let cells: [TerminalCell]

    public static func decode(_ data: Data) throws -> TerminalFrame {
        var reader = Reader(data: data)
        guard data.count >= 36 && data.count <= 4 * 1024 * 1024 else { throw FrameError.malformed }
        let columns: Int = Int(try reader.int32())
        let rows: Int = Int(try reader.int32())
        guard (2...500).contains(columns), (2...300).contains(rows) else { throw FrameError.malformed }
        let x = Int(try reader.int32()), y = Int(try reader.int32())
        let style = try reader.uint32(), flags = try reader.uint32(), fg = try reader.uint32()
        let bg = try reader.uint32(), cursorColor = try reader.uint32()
        guard (0..<columns).contains(x), (0..<rows).contains(y) else { throw FrameError.malformed }
        var cells: [TerminalCell] = []; cells.reserveCapacity(columns * rows)
        for _ in 0..<(columns * rows) {
            let width = try reader.int32(), attrs = try reader.uint32(), cellFG = try reader.uint32(), cellBG = try reader.uint32()
            let length = Int(try reader.int32())
            guard (0...2).contains(width), (0...1024).contains(length) else { throw FrameError.malformed }
            let bytes = try reader.bytes(length)
            guard let text = String(data: bytes, encoding: .utf8) else { throw FrameError.malformed }
            cells.append(TerminalCell(width: width, flags: attrs, foreground: cellFG, background: cellBG, text: text))
        }
        guard reader.remaining == 0 else { throw FrameError.malformed }
        return TerminalFrame(columns: columns, rows: rows, cursorX: x, cursorY: y, cursorStyle: style, cursorFlags: flags, foreground: fg, background: bg, cursorColor: cursorColor, cells: cells)
    }
}
public enum FrameError: Error, Equatable { case malformed }
private struct Reader {
    let data: Data; var offset = 0
    var remaining: Int { data.count - offset }
    mutating func bytes(_ count: Int) throws -> Data { guard count >= 0 && count <= remaining else { throw FrameError.malformed }; defer { offset += count }; return data[offset..<offset+count] }
    mutating func int32() throws -> Int32 { let b = try bytes(4); return Int32(bitPattern: b.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian) }
    mutating func uint32() throws -> UInt32 { let b = try bytes(4); return b.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
}
