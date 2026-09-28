package io.angaz.sshepherd

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class TerminalFrameTest {
    @Test fun binaryInputPreservesUnicodeAndControlBytes() {
        val bytes = "🐑\u0003\u0000".toByteArray(Charsets.UTF_8)
        val frame = PtyFrames.input(bytes)
        assertEquals(1, frame[0].toInt())
        assertEquals(bytes.size, ByteBuffer.wrap(frame, 1, 4).int)
        assertArrayEquals(bytes, frame.copyOfRange(5, frame.size))
    }
    @Test fun geometryUsesBigEndianAndClamps() {
        assertArrayEquals(byteArrayOf(2, 0, 0, 0, 4, 0, 80, 0, 24), PtyFrames.resize(80, 24))
        assertArrayEquals(byteArrayOf(2, 0, 0, 0, 4, 1, -12, 0, 2), PtyFrames.resize(1000, 0))
    }
    @Test fun snapshotUsesNativeCellsWithoutAnsiOrHtmlParsing() {
        val b = ByteBuffer.allocate(36 + 4 * 20 + 1).order(ByteOrder.LITTLE_ENDIAN)
        listOf(2, 2, 1, 0, 1, 1, -1, -16777216, -1).forEach { b.putInt(it) }
        repeat(4) { i ->
            listOf(1, 0, -1, -16777216, if (i == 0) 1 else 0).forEach { b.putInt(it) }
            if (i == 0) b.put('A'.code.toByte())
        }
        val frame = TerminalFrame.decode(b.array())
        assertEquals("A", frame.cells[0].text)
        assertEquals(4, frame.cells.size)
        assertEquals(1, frame.cursorX)
    }
    @Test(expected = IllegalArgumentException::class) fun malformedSnapshotRejected() { TerminalFrame.decode(ByteArray(36)) }
}
