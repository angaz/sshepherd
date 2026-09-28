package io.angaz.sshepherd

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.os.SystemClock
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import kotlin.math.ceil
import kotlin.math.max

/** Native Android Canvas renderer over libghostty-vt's cell/grapheme grid. */
class TerminalView(context: Context) : View(context), AutoCloseable {
    var onInput: (ByteArray) -> Boolean = { false }
    var onGeometry: (Int, Int) -> Unit = { _, _ -> }
    var onFailure: (String) -> Unit = {}
    var onMessage: (String) -> Unit = {}
    var acceptingInput = false
        set(value) { if (!value) connection?.discardComposition(); field = value }
    var ctrlLatched = false
        set(value) {
            if (value && !field) { connection?.finishComposingText(); connection?.discardComposition() }
            field = value
        }
    var onCtrlConsumed: () -> Unit = {}
    var cols = 80; private set
    var rows = 24; private set
    private var engine = GhosttyNative.create(cols, rows)
    private var dirty = true
    private var snapshot: TerminalFrame? = null
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.MONOSPACE
        textSize = 13f * resources.displayMetrics.scaledDensity
    }
    private val fill = Paint()
    private val cellWidth = ceil(text.measureText("M")).toInt().coerceAtLeast(1)
    private val cellHeight = ceil(text.fontMetrics.descent - text.fontMetrics.ascent).toInt().coerceAtLeast(1)
    private val baseline = -text.fontMetrics.ascent
    private var connection: TerminalInputConnection? = null
    private var composition = ""
    private var touchId = -1
    private var touchX = 0f
    private var touchY = 0f
    private var deadAccent = 0
    private val blink = object : Runnable {
        override fun run() { if (engine != 0L && isAttachedToWindow) { invalidate(); postDelayed(this, 500) } }
    }
    init {
        isFocusable = true
        isFocusableInTouchMode = true
        contentDescription = "Remote Herdr terminal"
        setBackgroundColor(0xff10141c.toInt())
        importantForAutofill = IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
    }
    private inline fun safely(action: () -> Unit) {
        if (engine == 0L) return
        try { action() } catch (error: Exception) {
            close()
            post { onFailure(error.message ?: "Native terminal failed") }
        }
    }
    fun feed(bytes: ByteArray) = safely {
        GhosttyNative.write(engine, bytes)
        flushReplies()
        dirty = true
        postInvalidateOnAnimation()
    }
    private fun flushReplies() {
        val replies = GhosttyNative.replies(engine)
        if (replies.isNotEmpty()) onInput(replies)
    }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = safely {
        cols = (w / cellWidth).coerceIn(2, 500)
        rows = (h / cellHeight).coerceIn(2, 300)
        GhosttyNative.resize(engine, cols, rows, cellWidth, cellHeight)
        // PTY geometry first, then any in-band terminal size response.
        onGeometry(cols, rows)
        flushReplies()
        dirty = true
        invalidate()
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        safely {
            if (dirty) { snapshot = TerminalFrame.decode(GhosttyNative.frame(engine)); dirty = false }
            val frame = snapshot ?: return
            canvas.drawColor(frame.background)
            for (index in frame.cells.indices) {
                val cell = frame.cells[index]
                val x = (index % frame.cols * cellWidth).toFloat()
                val y = (index / frame.cols * cellHeight).toFloat()
                if (cell.background != frame.background) {
                    fill.color = cell.background
                    canvas.drawRect(x, y, x + cellWidth, y + cellHeight, fill)
                }
            }
            for (index in frame.cells.indices) {
                val cell = frame.cells[index]
                if (cell.width == 0 || cell.flags and 16 != 0) continue
                val x = (index % frame.cols * cellWidth).toFloat()
                val y = (index / frame.cols * cellHeight).toFloat()
                drawCell(canvas, cell, x, y, cell.foreground)
            }
            if (frame.cursorFlags and 1 != 0 && (frame.cursorFlags and 2 == 0 || SystemClock.uptimeMillis() % 1000 < 500)) {
                val x = (frame.cursorX * cellWidth).toFloat()
                val y = (frame.cursorY * cellHeight).toFloat()
                fill.color = frame.cursorColor
                when (frame.cursorStyle) {
                    0 -> canvas.drawRect(x, y, x + max(2f, cellWidth / 7f), y + cellHeight, fill)
                    2 -> canvas.drawRect(x, y + cellHeight - 2, x + cellWidth, y + cellHeight, fill)
                    3 -> { fill.style = Paint.Style.STROKE; canvas.drawRect(x + 1, y + 1, x + cellWidth - 1, y + cellHeight - 1, fill); fill.style = Paint.Style.FILL }
                    else -> {
                        val cell = frame.cells[frame.cursorY * frame.cols + frame.cursorX]
                        canvas.drawRect(x, y, x + cellWidth * max(1, cell.width), y + cellHeight, fill)
                        if (cell.width > 0 && cell.flags and 16 == 0) drawCell(canvas, cell, x, y, cell.background)
                    }
                }
            }
            if (composition.isNotEmpty()) {
                // Control-containing or Ctrl-latched pre-edit waits for commitment.
                fill.color = 0xff263a4b.toInt()
                canvas.drawRect(0f, height - cellHeight.toFloat(), width.toFloat(), height.toFloat(), fill)
                text.color = 0xff7ce4c6.toInt(); text.alpha = 255; text.isFakeBoldText = false; text.textSkewX = 0f
                canvas.drawText(composition, 4f, height - cellHeight + baseline, text)
            }
        }
    }
    private fun drawCell(canvas: Canvas, cell: TerminalCell, x: Float, y: Float, foreground: Int) {
        canvas.save()
        canvas.clipRect(x, y, x + cell.width * cellWidth, y + cellHeight)
        text.color = foreground
        text.alpha = if (cell.flags and 32 != 0) 150 else 255
        text.isFakeBoldText = cell.flags and 1 != 0
        text.textSkewX = if (cell.flags and 2 != 0) -0.2f else 0f
        if (cell.text.isNotEmpty()) canvas.drawText(cell.text, x, y + baseline, text)
        fill.color = foreground
        if (cell.flags and 4 != 0) canvas.drawRect(x, y + cellHeight - 2, x + cell.width * cellWidth, y + cellHeight - 1, fill)
        if (cell.flags and 8 != 0) canvas.drawRect(x, y + cellHeight / 2, x + cell.width * cellWidth, y + cellHeight / 2 + 1, fill)
        if (cell.flags and 64 != 0) canvas.drawRect(x, y, x + cell.width * cellWidth, y + 1, fill)
        canvas.restore()
    }
    override fun onCheckIsTextEditor() = true
    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        configureTerminalEditor(outAttrs)
        connection?.closeConnection()
        return TerminalInputConnection(this, ::applyImeEdit, ::handleKey, { !ctrlLatched }) {
            composition = it; invalidate()
        }.also { connection = it }
    }
    private fun applyImeEdit(edit: TerminalEdit): Boolean {
        if (!acceptingInput || engine == 0L) return false
        var accepted = false
        safely {
            val bytes = java.io.ByteArrayOutputStream()
            fun keys(code: Int, count: Int) {
                repeat(count) {
                    bytes.write(GhosttyNative.key(engine, code, 0, 0, 1, byteArrayOf()))
                    bytes.write(GhosttyNative.key(engine, code, 0, 0, 0, byteArrayOf()))
                }
            }
            keys(KeyEvent.KEYCODE_DPAD_RIGHT, edit.right)
            keys(KeyEvent.KEYCODE_DEL, edit.erase)
            val cp = if (edit.text.codePointCount(0, edit.text.length) == 1) edit.text.uppercase().codePointAt(0) else -1
            if (ctrlLatched && cp in 64..95) bytes.write(cp and 31)
            else bytes.write(edit.text.toByteArray(Charsets.UTF_8))
            keys(KeyEvent.KEYCODE_DPAD_LEFT, edit.left)
            if (edit.extraBefore != 0) {
                keys(KeyEvent.KEYCODE_DPAD_LEFT, edit.protectedPoints)
                keys(KeyEvent.KEYCODE_DEL, edit.extraBefore)
                keys(KeyEvent.KEYCODE_DPAD_RIGHT, edit.protectedPoints)
            }
            keys(KeyEvent.KEYCODE_FORWARD_DEL, edit.extraAfter)
            accepted = bytes.size() == 0 || onInput(bytes.toByteArray())
            if (accepted) consumeCtrl()
        }
        return accepted
    }
    private fun consumeCtrl() { if (ctrlLatched) { ctrlLatched = false; onCtrlConsumed() } }
    fun sendRaw(bytes: ByteArray) {
        if (acceptingInput && bytes.isNotEmpty()) onInput(bytes)
    }
    fun accessory(code: Int, mods: Int = 0) = safely {
        if (!acceptingInput) return
        if (connection?.finishComposingText() == false) return
        connection?.discardComposition()
        val combined = mods or if (ctrlLatched) 2 else 0
        val utf8 = if (code in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z) ('a'.code + code - KeyEvent.KEYCODE_A).toChar().toString().toByteArray() else byteArrayOf()
        sendRaw(GhosttyNative.key(engine, code, combined, 0, 1, utf8))
        sendRaw(GhosttyNative.key(engine, code, combined, 0, 0, utf8))
        consumeCtrl()
    }
    fun herdrAction(key: Char) {
        if (!acceptingInput) return
        if (connection?.finishComposingText() == false) return
        connection?.discardComposition()
        sendRaw(byteArrayOf(1, key.code.toByte()))
    }
    fun paste(value: String) = safely {
        if (!acceptingInput) return
        if (connection?.finishComposingText() == false) return
        connection?.discardComposition()
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size > 60000) { onMessage("Paste exceeds 60 KB"); return }
        // Do not permit a clipboard string to terminate bracketed paste early.
        if (value.contains('\u001b')) { onMessage("Paste contains escape characters"); return }
        val bracketed = GhosttyNative.mode(engine, 2004)
        sendRaw(if (bracketed) "\u001b[200~".toByteArray() + bytes + "\u001b[201~".toByteArray() else bytes)
    }
    private fun handleKey(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_BACK || event.keyCode in KeyEvent.KEYCODE_VOLUME_UP..KeyEvent.KEYCODE_VOLUME_DOWN) return false
        if (engine == 0L || !acceptingInput) return true
        safely {
            if (event.action == KeyEvent.ACTION_DOWN) {
                if (connection?.finishComposingText() == false) return true
                connection?.discardComposition()
            }
            val keyText = TerminalKeys.resolve(event)
            var point = keyText.codepoint
            if (point and KeyCharacterMap.COMBINING_ACCENT != 0) {
                if (event.action == KeyEvent.ACTION_DOWN) deadAccent = point and KeyCharacterMap.COMBINING_ACCENT_MASK
                return true
            }
            if (deadAccent != 0 && point != 0 && event.action == KeyEvent.ACTION_DOWN) {
                point = KeyEvent.getDeadChar(deadAccent, point).takeIf { it != 0 } ?: point
                deadAccent = 0
            }
            val utf8 = if (point > 0 && Character.isValidCodePoint(point)) String(Character.toChars(point)).toByteArray(Charsets.UTF_8) else byteArrayOf()
            val action = if (event.action == KeyEvent.ACTION_UP) 0 else if (event.repeatCount > 0) 2 else 1
            sendRaw(GhosttyNative.key(engine, event.keyCode, keyText.mods or if (ctrlLatched) 2 else 0, keyText.consumedMods, action, utf8))
            if (action == 1) consumeCtrl()
        }
        return true
    }
    override fun onKeyDown(keyCode: Int, event: KeyEvent) = handleKey(event) || super.onKeyDown(keyCode, event)
    override fun onKeyUp(keyCode: Int, event: KeyEvent) = handleKey(event) || super.onKeyUp(keyCode, event)
    fun showKeyboard() {
        requestFocus()
        (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
    }
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (engine == 0L) return false
        safely {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    if (connection?.finishComposingText() == false) return true
                    connection?.discardComposition()
                    requestFocus(); touchId = event.getPointerId(0); touchX = event.x; touchY = event.y
                    if (acceptingInput) sendRaw(GhosttyNative.mouse(engine, 0, 1, touchX.toDouble(), touchY.toDouble(), 0))
                }
                MotionEvent.ACTION_MOVE -> {
                    val index = event.findPointerIndex(touchId)
                    if (index >= 0) {
                        touchX = event.getX(index); touchY = event.getY(index)
                        if (acceptingInput) sendRaw(GhosttyNative.mouse(engine, 2, 1, touchX.toDouble(), touchY.toDouble(), 0))
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (touchId != -1 && acceptingInput) sendRaw(GhosttyNative.mouse(engine, 1, 1, touchX.toDouble(), touchY.toDouble(), 0))
                    touchId = -1
                    if (event.actionMasked == MotionEvent.ACTION_UP) performClick()
                }
            }
        }
        return true
    }
    override fun performClick(): Boolean { super.performClick(); return true }
    override fun onAttachedToWindow() { super.onAttachedToWindow(); post(blink) }
    override fun onDetachedFromWindow() { removeCallbacks(blink); super.onDetachedFromWindow() }
    override fun close() {
        connection?.closeConnection()
        removeCallbacks(blink)
        if (engine != 0L) { val old = engine; engine = 0; GhosttyNative.destroy(old) }
        snapshot = null
    }
}
