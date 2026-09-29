package io.angaz.sshepherd

import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

internal sealed class PasteContent {
    data class Text(val value: String) : PasteContent()
    data class Image(val extension: String, val bytes: ByteArray) : PasteContent()
}

/** No filenames or content URIs are ever inserted as terminal commands. */
internal object ContentFiles {
    const val IMAGE_LIMIT = 16 * 1024 * 1024 // Herdr MAX_CLIPBOARD_IMAGE_PAYLOAD
    const val TEXT_LIMIT = 60000
    private fun validBitmapHeader(bytes: ByteArray): Boolean {
        if (bytes.size < 26) return false
        val header = ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        return header.getInt(2) == bytes.size && header.getInt(6) == 0 &&
            header.getInt(10) in 26..bytes.size && header.getInt(14) in listOf(12, 40, 52, 56, 64, 108, 124)
    }
    fun read(stream: InputStream): PasteContent {
        val output = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(32768)
        while (true) {
            check(!Thread.currentThread().isInterrupted) { "File read cancelled" }
            val n = stream.read(chunk)
            if (n < 0) break
            require(output.size() + n <= IMAGE_LIMIT) { "File exceeds 16 MiB" }
            output.write(chunk, 0, n)
        }
        val bytes = output.toByteArray()
        fun starts(vararg values: Int) = bytes.size >= values.size && values.indices.all { (bytes[it].toInt() and 255) == values[it] }
        val extension = when {
            starts(137,80,78,71,13,10,26,10) -> "png"
            starts(255,216,255) -> "jpg"
            starts(71,73,70,56,55,97) || starts(71,73,70,56,57,97) -> "gif"
            bytes.size >= 12 && String(bytes, 0, 4, Charsets.US_ASCII) == "RIFF" && String(bytes, 8, 4, Charsets.US_ASCII) == "WEBP" -> "webp"
            starts(66,77) && validBitmapHeader(bytes) -> "bmp"
            else -> null
        }
        if (extension != null) return PasteContent.Image(extension, bytes)
        require(bytes.size <= TEXT_LIMIT) { "Text paste exceeds 60 KB, or image format is unsupported" }
        val text = try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString().removePrefix("\uFEFF")
        } catch (_: Exception) { throw IllegalArgumentException("Use a supported image or UTF-8 text file") }
        require(text.none { (it < ' ' && it !in "\r\n\t") || it == '\u007f' || it in '\u0080'..'\u009f' }) {
            "Binary files and terminal control characters cannot be pasted"
        }
        require(text.isNotEmpty()) { "File is empty" }
        return PasteContent.Text(text)
    }
}

/** Resumable transport already deduplicates frames. Keep one frame until accepted. */
internal class ImageTransfer(private val image: PasteContent.Image) {
    private var offset = 0
    private var phase = 0
    var done = false; private set
    fun pump(send: (ByteArray) -> Boolean) {
        repeat(4) {
            if (done) return
            val frame = when (phase) {
                0 -> PtyFrames.content(3, ByteBuffer.allocate(4 + image.extension.length)
                    .putInt(image.bytes.size).put(image.extension.toByteArray(Charsets.US_ASCII)).array())
                1 -> PtyFrames.content(4, image.bytes.copyOfRange(offset, minOf(offset + 32768, image.bytes.size)))
                else -> PtyFrames.content(5, byteArrayOf())
            }
            if (!send(frame)) return
            when (phase) {
                0 -> phase = 1
                1 -> { offset += frame.size - 5; if (offset == image.bytes.size) phase = 2 }
                else -> done = true
            }
        }
    }
}
