package io.angaz.sshepherd

import java.nio.ByteBuffer
import java.nio.ByteOrder

internal data class TerminalCell(val width: Int, val flags: Int, val foreground: Int, val background: Int, val text: String)
internal data class TerminalFrame(
    val cols: Int, val rows: Int, val cursorX: Int, val cursorY: Int,
    val cursorStyle: Int, val cursorFlags: Int, val foreground: Int,
    val background: Int, val cursorColor: Int, val cells: List<TerminalCell>
) {
    companion object {
        fun decode(bytes: ByteArray): TerminalFrame {
            require(bytes.size in 36..4 * 1024 * 1024)
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val cols = buffer.int; val rows = buffer.int
            require(cols in 2..500 && rows in 2..300)
            val x = buffer.int; val y = buffer.int
            val style = buffer.int; val flags = buffer.int
            val fg = buffer.int; val bg = buffer.int; val cursorColor = buffer.int
            require(x in 0 until cols && y in 0 until rows)
            val cells = ArrayList<TerminalCell>(cols * rows)
            repeat(cols * rows) {
                require(buffer.remaining() >= 20)
                val width = buffer.int; val attrs = buffer.int
                val foreground = buffer.int; val background = buffer.int
                val len = buffer.int
                require(width in 0..2 && len in 0..1024 && len <= buffer.remaining())
                val text = ByteArray(len); buffer.get(text)
                cells.add(TerminalCell(width, attrs, foreground, background, String(text, Charsets.UTF_8)))
            }
            require(!buffer.hasRemaining())
            return TerminalFrame(cols, rows, x, y, style, flags, fg, bg, cursorColor, cells)
        }
    }
}

/** The remote Python PTY bridge's bounded binary input protocol. */
internal object PtyFrames {
    fun input(bytes: ByteArray): ByteArray {
        require(bytes.size <= 65536)
        return ByteBuffer.allocate(bytes.size + 5).put(1).putInt(bytes.size).put(bytes).array()
    }
    fun content(kind: Int, bytes: ByteArray): ByteArray {
        require(kind in 3..5 && bytes.size <= 65536)
        return ByteBuffer.allocate(bytes.size + 5).put(kind.toByte()).putInt(bytes.size).put(bytes).array()
    }
    fun directory(record: org.json.JSONObject): ByteArray {
        val bytes = record.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= 1024)
        return ByteBuffer.allocate(bytes.size + 5).put(6).putInt(bytes.size).put(bytes).array()
    }
    fun resize(cols: Int, rows: Int): ByteArray = ByteBuffer.allocate(9).put(2).putInt(4)
        .putShort(cols.coerceIn(2, 500).toShort()).putShort(rows.coerceIn(2, 300).toShort()).array()
}
