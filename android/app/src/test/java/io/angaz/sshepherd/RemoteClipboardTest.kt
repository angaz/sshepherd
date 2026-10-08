package io.angaz.sshepherd

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class RemoteClipboardTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val clipboard get() = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    @Test fun decodedRemoteTextReachesAndroidClipboardWithoutTransformation() {
        val text = "Clipboard café 🐑\nnext line\twith tab"
        assertTrue(RemoteClipboard.write(context, text.toByteArray(Charsets.UTF_8)))
        assertEquals(text, clipboard.primaryClip!!.getItemAt(0).text.toString())
        assertEquals("SSHepherd terminal", clipboard.primaryClip!!.description.label)
        assertTrue(clipboard.primaryClip!!.description.hasMimeType("text/plain"))
    }
    @Test fun invalidUtf8AndOversizedPayloadLeaveClipboardUnchanged() {
        clipboard.setPrimaryClip(ClipData.newPlainText("existing", "keep"))
        assertFalse(RemoteClipboard.write(context, byteArrayOf(0xc3.toByte(), 0x28)))
        assertFalse(RemoteClipboard.write(context, ByteArray(60001) { 65 }))
        assertEquals("keep", clipboard.primaryClip!!.getItemAt(0).text.toString())
    }
    @Test fun exactByteLimitAndExplicitEmptyTextAreSupported() {
        val bytes = "界".repeat(20000).toByteArray(Charsets.UTF_8)
        assertEquals(60000, bytes.size)
        assertTrue(RemoteClipboard.write(context, bytes))
        assertEquals("界".repeat(20000), clipboard.primaryClip!!.getItemAt(0).text.toString())
        assertTrue(RemoteClipboard.write(context, byteArrayOf()))
        assertEquals("", clipboard.primaryClip!!.getItemAt(0).text.toString())
    }
}
