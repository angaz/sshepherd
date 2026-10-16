package io.angaz.sshepherd

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import java.net.URI

/** Only web links are launchable: remote output must not dispatch arbitrary app intents. */
internal object TerminalLinks {
    private val web = Regex("(?:https?://|www\\.)[^\\s<>\"'`\\p{Cntrl}]+", RegexOption.IGNORE_CASE)

    fun webUrl(value: String): String? {
        if (value.length !in 1..8192 || value.any { it.isWhitespace() || it.isISOControl() }) return null
        val url = if (value.startsWith("www.", true)) "https://$value" else value
        val uri = try { URI(url) } catch (_: Exception) { return null }
        if (!uri.scheme.equals("https", true) && !uri.scheme.equals("http", true)) return null
        if (uri.host.isNullOrEmpty() || uri.rawUserInfo != null) return null
        return uri.scheme.lowercase() + url.substring(uri.scheme.length)
    }

    fun at(frame: TerminalFrame, col: Int, row: Int): String? {
        if (col !in 0 until frame.cols || row !in 0 until frame.rows) return null
        fun wrapped(y: Int) = frame.cells[y * frame.cols].flags and 128 != 0
        var first = row
        while (first > 0 && wrapped(first - 1)) first--
        var last = row
        while (last + 1 < frame.rows && wrapped(last)) last++
        val text = StringBuilder()
        var offset = -1
        for (index in first * frame.cols until (last + 1) * frame.cols) {
            val cell = frame.cells[index]
            val start = text.length
            if (cell.width != 0) text.append(if (cell.flags and 16 != 0) " " else cell.text.ifEmpty { " " })
            if (index == row * frame.cols + col) {
                // A wide glyph's trailing cell belongs to the same grapheme.
                offset = if (cell.width == 0) (start - 1).coerceAtLeast(0) else start
            }
        }
        for (match in web.findAll(text)) {
            var value = match.value.trimEnd('.', ',', ';', ':', '!', '?')
            for ((open, close) in listOf('(' to ')', '[' to ']', '{' to '}')) {
                while (value.endsWith(close) && value.count { it == close } > value.count { it == open }) value = value.dropLast(1)
            }
            if (offset in match.range.first until match.range.first + value.length) return webUrl(value)
        }
        return null
    }

    fun open(context: Context, url: String, message: (String) -> Unit) {
        val safe = webUrl(url) ?: return
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(safe)).addCategory(Intent.CATEGORY_BROWSABLE)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: ActivityNotFoundException) {
            message("No app is available to open this link")
        } catch (_: SecurityException) {
            message("Unable to open this link")
        }
    }
}
