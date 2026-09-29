package io.angaz.sshepherd

import android.text.Editable
import android.text.InputType
import android.text.Selection
import android.text.SpannableStringBuilder
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager

internal fun configureTerminalEditor(info: EditorInfo) {
    info.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_AUTO_CORRECT
    info.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN or
        EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING or EditorInfo.IME_ACTION_NONE
    info.contentMimeTypes = arrayOf("image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp")
    info.initialCapsMode = 0
    info.initialSelStart = 0
    info.initialSelEnd = 0
}

/** An atomic edit of phone-owned text, expressed as terminal keys and literal UTF-8. */
internal data class TerminalEdit(
    val right: Int, val erase: Int, val text: String, val left: Int,
    val extraBefore: Int = 0, val extraAfter: Int = 0, val protectedPoints: Int = 0
)

/** Mirror IME composition as reversible terminal edits, not just final commits.
 * Retain bounded editing context so candidates can replace phone-typed words.
 * Screen output is never imported into the keyboard's editable context.
 */
internal class TerminalInputConnection(
    private val target: View,
    private val applyEdit: (TerminalEdit) -> Boolean,
    private val key: (KeyEvent) -> Boolean,
    private val retainContext: () -> Boolean = { true },
    private val content: (android.view.inputmethod.InputContentInfo, Int) -> Boolean = { _, _ -> false },
    private val composingChanged: (String) -> Unit = {}
) : BaseInputConnection(target, true) {
    private val buffer = SpannableStringBuilder()
    private var sent = ""
    private var cursor = 0
    private var batch = 0
    private var active = true
    private val imeArrowKeys = mutableSetOf<Int>()
    init { Selection.setSelection(buffer, 0) }
    override fun getEditable(): Editable = buffer
    private fun notifyIme() {
        val start = getComposingSpanStart(buffer)
        val end = getComposingSpanEnd(buffer)
        // Only deferred control-key composition needs a local overlay. Normal
        // composition is already visible through the remote terminal's echo.
        composingChanged(if (buffer.toString() != sent && start >= 0 && end >= start) buffer.substring(start, end) else "")
        if (batch == 0) (target.context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as InputMethodManager)
            .updateSelection(target, Selection.getSelectionStart(buffer), Selection.getSelectionEnd(buffer), start, end)
    }
    override fun beginBatchEdit(): Boolean { batch++; return true }
    override fun endBatchEdit(): Boolean { if (batch > 0) batch--; notifyIme(); return true }
    override fun setSelection(start: Int, end: Int): Boolean {
        if (!active || start !in 0..buffer.length || end !in 0..buffer.length) return false
        // Space-bar gestures use selection offsets, not necessarily key events.
        // Only mirror our owned, already-sent text; never guess screen contents.
        fun boundary(offset: Int) = offset == 0 || offset == buffer.length ||
            !(Character.isHighSurrogate(buffer[offset - 1]) && Character.isLowSurrogate(buffer[offset]))
        if (!boundary(start) || !boundary(end)) return false
        if (retainContext() && sent == buffer.toString() && cursor != end) {
            val right = if (end > cursor) sent.codePointCount(cursor, end) else 0
            val left = if (end < cursor) sent.codePointCount(end, cursor) else 0
            if (!applyEdit(TerminalEdit(right, 0, "", left))) { notifyIme(); return false }
            cursor = end
        }
        val result = super.setSelection(start, end)
        notifyIme()
        return result
    }
    override fun setComposingRegion(start: Int, end: Int): Boolean {
        if (!active || start !in 0..buffer.length || end !in 0..buffer.length) return false
        val result = super.setComposingRegion(start, end)
        notifyIme()
        return result
    }
    private fun fits(text: CharSequence?): Boolean {
        val a = getComposingSpanStart(buffer).takeIf { it >= 0 } ?: Selection.getSelectionStart(buffer)
        val b = getComposingSpanEnd(buffer).takeIf { it >= 0 } ?: Selection.getSelectionEnd(buffer)
        return (text?.length ?: 0) <= 16384 &&
            buffer.length - kotlin.math.abs(b - a) + (text?.length ?: 0) <= 16896
    }
    override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
        if (!active || !fits(text)) return false
        if (!super.setComposingText(text, newCursorPosition)) return false
        // Control actions must wait for commitment: executing them during
        // composition would clear context and replay them on the matching commit.
        if (deferComposition()) { notifyIme(); return true }
        return synchronize()
    }
    private fun deferComposition() = !retainContext() || buffer.any { it < ' ' || it == '\u007f' }
    override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
        if (!active || !fits(text)) return false
        super.commitText(text, newCursorPosition)
        return synchronize()
    }
    @android.annotation.TargetApi(34)
    override fun replaceText(start: Int, end: Int, text: CharSequence, newCursorPosition: Int,
                             textAttribute: android.view.inputmethod.TextAttribute?): Boolean {
        // API 34's BaseInputConnection implementation edits the Editable directly,
        // bypassing our commitText override. Gboard can use this for corrections.
        if (!active || start !in 0..buffer.length || end !in 0..buffer.length) return false
        val a = minOf(start, end)
        val b = maxOf(start, end)
        if (text.length > 16384 || buffer.length - (b - a) + text.length > 16896) return false
        beginBatchEdit()
        try {
            removeComposingSpans(buffer)
            Selection.setSelection(buffer, a, b)
            // Do not finish the old composition first: replace it in one edit.
            super.commitText(text, newCursorPosition)
            return synchronize()
        } finally { endBatchEdit() }
    }
    override fun finishComposingText(): Boolean {
        if (!active) return false
        super.finishComposingText()
        return synchronize()
    }
    private fun synchronize(extraBefore: Int = 0, extraAfter: Int = 0, protectedPoints: Int = 0): Boolean {
        val next = buffer.toString()
        var prefix = 0
        while (prefix < sent.length && prefix < next.length && sent[prefix] == next[prefix]) prefix++
        if (prefix > 0 && prefix < sent.length && Character.isLowSurrogate(sent[prefix])) prefix--
        val selection = Selection.getSelectionEnd(buffer).coerceIn(0, next.length)
        val keep = retainContext() && next.none { it < ' ' || it == '\u007f' }
        val edit = TerminalEdit(sent.codePointCount(cursor, sent.length),
            sent.codePointCount(prefix, sent.length), next.substring(prefix),
            if (keep) next.codePointCount(selection, next.length) else 0,
            extraBefore, extraAfter, protectedPoints)
        if (sent != next || cursor != selection || extraBefore != 0 || extraAfter != 0) {
            if (!applyEdit(edit)) { discardComposition(); return false }
        }
        sent = next
        cursor = selection
        if (!keep || extraBefore != 0 || extraAfter != 0) discardComposition() else {
            // Trim bookkeeping only, never the remote command. If the cursor
            // is in a long edit, abandon context rather than retain it unbounded.
            val composing = getComposingSpanStart(buffer) >= 0
            if (!composing && buffer.length > 512 && cursor != buffer.length) {
                discardComposition()
                return true
            }
            if (!composing && buffer.length > 512) {
                var cut = buffer.length - 512
                if (Character.isLowSurrogate(buffer[cut])) cut++
                buffer.delete(0, cut)
                sent = buffer.toString(); cursor = sent.length
                Selection.setSelection(buffer, cursor)
            }
            notifyIme()
        }
        return true
    }
    override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean =
        delete(beforeLength, afterLength, false)
    override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean =
        delete(beforeLength, afterLength, true)
    private fun delete(before: Int, after: Int, points: Boolean): Boolean {
        if (!active || before !in 0..1024 || after !in 0..1024) return false
        var a = minOf(Selection.getSelectionStart(buffer), Selection.getSelectionEnd(buffer))
        var b = maxOf(Selection.getSelectionStart(buffer), Selection.getSelectionEnd(buffer))
        val compStart = getComposingSpanStart(buffer)
        val compEnd = getComposingSpanEnd(buffer)
        val composing = compStart >= 0 && compEnd >= 0
        if (composing) { a = minOf(a, compStart); b = maxOf(b, compEnd) }
        val availableBefore = if (points) Character.codePointCount(buffer, 0, a) else a
        val availableAfter = if (points) Character.codePointCount(buffer, b, buffer.length) else buffer.length - b
        val extraBefore = (before - availableBefore).coerceAtLeast(0)
        val extraAfter = (after - availableAfter).coerceAtLeast(0)
        var start = if (points) Character.offsetByCodePoints(buffer, a, -minOf(before, availableBefore))
            else (a - before).coerceAtLeast(0)
        var end = if (points) Character.offsetByCodePoints(buffer, b, minOf(after, availableAfter))
            else (b + after).coerceAtMost(buffer.length)
        // Android's UTF-16 API must not leave half an emoji in the terminal.
        if (start > 0 && start < buffer.length && Character.isLowSurrogate(buffer[start]) && Character.isHighSurrogate(buffer[start - 1])) start--
        if (end > 0 && end < buffer.length && Character.isLowSurrogate(buffer[end]) && Character.isHighSurrogate(buffer[end - 1])) end++
        val protectedPoints = Character.codePointCount(buffer, a, b)
        val result = super.deleteSurroundingText(a - start, end - b)
        if (!result) return false
        if (composing && deferComposition() && extraBefore == 0 && extraAfter == 0) { notifyIme(); return true }
        if (extraBefore != 0 || extraAfter != 0) {
            super.finishComposingText()
            Selection.setSelection(buffer, start + b - a)
        }
        return synchronize(extraBefore, extraAfter, protectedPoints)
    }
    override fun commitContent(info: android.view.inputmethod.InputContentInfo, flags: Int, opts: android.os.Bundle?): Boolean {
        if (!active) return false
        return content(info, flags)
    }
    override fun sendKeyEvent(event: KeyEvent): Boolean {
        if (!active) return false
        if (event.action == KeyEvent.ACTION_UP && imeArrowKeys.remove(event.keyCode)) return true
        // Some IMEs implement cursor gestures as synthetic arrow keys instead.
        if (event.action == KeyEvent.ACTION_DOWN && event.hasNoModifiers() && retainContext() &&
            event.keyCode in listOf(KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT) &&
            sent.isNotEmpty() && sent == buffer.toString()) {
            val backwards = event.keyCode == KeyEvent.KEYCODE_DPAD_LEFT
            if ((backwards && cursor > 0) || (!backwards && cursor < sent.length)) {
                val next = sent.offsetByCodePoints(cursor, if (backwards) -1 else 1)
                imeArrowKeys.add(event.keyCode)
                return setSelection(next, next)
            }
            // Outside the known context, preserve normal terminal arrow behavior.
        }
        if (event.action == KeyEvent.ACTION_DOWN) {
            if (!finishComposingText()) return false
            discardComposition()
        }
        return key(event)
    }
    private fun syntheticKey(code: Int): Boolean {
        val handled = key(KeyEvent(KeyEvent.ACTION_DOWN, code))
        key(KeyEvent(KeyEvent.ACTION_UP, code))
        return handled
    }
    override fun performEditorAction(editorAction: Int): Boolean {
        if (!finishComposingText()) return false
        discardComposition()
        return syntheticKey(KeyEvent.KEYCODE_ENTER)
    }
    fun discardComposition() {
        buffer.clear(); removeComposingSpans(buffer); Selection.setSelection(buffer, 0)
        sent = ""; cursor = 0; imeArrowKeys.clear(); notifyIme()
    }
    override fun closeConnection() { discardComposition(); active = false; super.closeConnection() }
}
