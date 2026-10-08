package io.angaz.sshepherd

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** Write-only terminal clipboard support. Never reads the phone clipboard. */
internal object RemoteClipboard {
    fun write(context: Context, bytes: ByteArray): Boolean {
        if (bytes.size > 60000) return false
        return try {
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("SSHepherd terminal", text))
            true
        } catch (_: Exception) { false }
    }
}
