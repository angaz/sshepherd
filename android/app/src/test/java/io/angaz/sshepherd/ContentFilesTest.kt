package io.angaz.sshepherd

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.nio.ByteBuffer

class ContentFilesTest {
    @Test fun utf8TextFilePastesContentsNotPath() {
        assertEquals(PasteContent.Text("hello 🐑\n"), ContentFiles.read(ByteArrayInputStream("\uFEFFhello 🐑\n".toByteArray())))
    }
    @Test fun bitmapDocumentationIsTextNotAnImage() {
        val text = "BMP documentation\n"
        assertEquals(PasteContent.Text(text), ContentFiles.read(ByteArrayInputStream(text.toByteArray())))
    }
    @Test fun imageUsesSignatureNotUntrustedFilenameOrMime() {
        val data = byteArrayOf(137.toByte(),80,78,71,13,10,26,10,0)
        val image = ContentFiles.read(ByteArrayInputStream(data)) as PasteContent.Image
        assertEquals("png", image.extension)
        assertArrayEquals(data, image.bytes)
    }
    @Test fun rejectsBinaryControlsInvalidUtf8AndOversizedText() {
        for (bytes in listOf(byteArrayOf(0), byteArrayOf(0xff.toByte()), "\u001b[201~".toByteArray(), ByteArray(60001) { 65 })) {
            assertThrows(IllegalArgumentException::class.java) { ContentFiles.read(ByteArrayInputStream(bytes)) }
        }
    }
    @Test fun imageTransferRetainsRejectedFrameAndOrdersAllChunks() {
        val data = ByteArray(100000) { (it % 255).toByte() }
        val transfer = ImageTransfer(PasteContent.Image("png", data))
        val frames = mutableListOf<ByteArray>()
        var rejected: ByteArray? = null
        transfer.pump { rejected = it; false }
        assertFalse(transfer.done)
        while (!transfer.done) transfer.pump { frames.add(it); true }
        assertArrayEquals(rejected, frames.first())
        assertEquals(3, frames.first()[0].toInt())
        assertEquals(5, frames.last()[0].toInt())
        assertEquals(data.size, ByteBuffer.wrap(frames.first(), 5, 4).int)
        val chunks = frames.drop(1).dropLast(1)
        assertTrue(chunks.all { it[0].toInt() == 4 && it.size <= 32773 })
        assertArrayEquals(data, chunks.flatMap { it.drop(5) }.toByteArray())
    }
}
