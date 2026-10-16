package io.angaz.sshepherd

import android.view.MotionEvent
import android.view.ViewConfiguration
import kotlin.math.abs

/** Delay a remote press only when it might be a local link tap. Drags retain mouse input. */
internal class TerminalTouch(
    private val slop: Int,
    private val linkAt: (Float, Float) -> String?,
    private val mouse: (Int, Float, Float) -> Unit,
    private val open: (String) -> Unit,
    private val click: () -> Unit
) {
    private var pointer = -1
    private var downX = 0f
    private var downY = 0f
    private var x = 0f
    private var y = 0f
    private var downTime = 0L
    private var pending: String? = null
    private fun startMouse() {
        if (pending != null) { pending = null; mouse(0, downX, downY) }
    }
    private fun moved() = abs(x - downX) > slop || abs(y - downY) > slop

    fun event(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pointer = event.getPointerId(0)
                downX = event.x; downY = event.y; x = downX; y = downY
                downTime = event.eventTime
                pending = linkAt(x, y)
                if (pending == null) mouse(0, x, y)
            }
            MotionEvent.ACTION_POINTER_DOWN -> if (pointer != -1) startMouse()
            MotionEvent.ACTION_MOVE -> {
                val index = event.findPointerIndex(pointer)
                if (index >= 0) {
                    x = event.getX(index); y = event.getY(index)
                    if (moved()) startMouse()
                    if (pending == null) mouse(2, x, y)
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_POINTER_UP -> {
                if (pointer == -1 || (event.actionMasked == MotionEvent.ACTION_POINTER_UP && event.getPointerId(event.actionIndex) != pointer)) return
                val index = event.findPointerIndex(pointer)
                if (index >= 0) { x = event.getX(index); y = event.getY(index) }
                val target = pending
                val activate = event.actionMasked == MotionEvent.ACTION_UP && target != null && !moved() &&
                    event.eventTime - downTime < ViewConfiguration.getLongPressTimeout() && linkAt(x, y) == target
                if (activate) open(target!!)
                else if (pending == null || event.actionMasked != MotionEvent.ACTION_CANCEL) {
                    startMouse()
                    mouse(1, x, y)
                }
                pointer = -1; pending = null
                if (event.actionMasked == MotionEvent.ACTION_UP) click()
            }
        }
    }
}
