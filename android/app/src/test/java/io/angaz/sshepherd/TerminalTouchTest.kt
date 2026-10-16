package io.angaz.sshepherd

import android.view.MotionEvent
import android.view.ViewConfiguration
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class TerminalTouchTest {
    private val mouse = mutableListOf<Triple<Int, Float, Float>>()
    private val opened = mutableListOf<String>()
    private var clicks = 0
    private var target: String? = "https://example.com"
    private val touch = TerminalTouch(8, { _, _ -> target }, { action, x, y -> mouse.add(Triple(action, x, y)) },
        { opened.add(it) }, { clicks++ })
    private fun event(action: Int, x: Float = 20f, y: Float = 30f, time: Long = 10) {
        val event = MotionEvent.obtain(0, time, action, x, y, 0)
        try { touch.event(event) } finally { event.recycle() }
    }
    @Test fun linkTapOpensOnceOnReleaseWithoutSendingRemoteClick() {
        event(MotionEvent.ACTION_DOWN)
        assertTrue(opened.isEmpty()); assertTrue(mouse.isEmpty())
        event(MotionEvent.ACTION_UP, 22f, 31f, 100)
        assertEquals(listOf("https://example.com"), opened)
        assertTrue(mouse.isEmpty()); assertEquals(1, clicks)
    }
    @Test fun nonLinkTapAndDragKeepMousePressMoveRelease() {
        target = null
        event(MotionEvent.ACTION_DOWN)
        assertEquals(listOf(0), mouse.map { it.first })
        event(MotionEvent.ACTION_MOVE, 25f, 31f)
        event(MotionEvent.ACTION_UP, 25f, 31f)
        assertEquals(listOf(0, 2, 1), mouse.map { it.first }); assertTrue(opened.isEmpty())
    }
    @Test fun draggingFromLinkReplaysOriginalPressAndNeverOpensEvenIfItReturns() {
        event(MotionEvent.ACTION_DOWN)
        event(MotionEvent.ACTION_MOVE, 50f, 60f)
        event(MotionEvent.ACTION_MOVE)
        event(MotionEvent.ACTION_UP)
        assertEquals(Triple(0, 20f, 30f), mouse.first())
        assertEquals(listOf(0, 2, 2, 1), mouse.map { it.first }); assertTrue(opened.isEmpty())
    }
    @Test fun cancelledLinkTapDoesNothingAndCancelledRemoteDragReleases() {
        event(MotionEvent.ACTION_DOWN); event(MotionEvent.ACTION_CANCEL)
        assertTrue(mouse.isEmpty()); assertTrue(opened.isEmpty()); assertEquals(0, clicks)
        event(MotionEvent.ACTION_DOWN); event(MotionEvent.ACTION_MOVE, 60f)
        event(MotionEvent.ACTION_CANCEL)
        assertEquals(listOf(0, 2, 1), mouse.map { it.first }); assertTrue(opened.isEmpty())
    }
    @Test fun longPressChangedLinkAndUnreportedMovementDoNotOpen() {
        event(MotionEvent.ACTION_DOWN)
        event(MotionEvent.ACTION_UP, time = ViewConfiguration.getLongPressTimeout().toLong() + 20)
        assertEquals(listOf(0, 1), mouse.map { it.first }); assertTrue(opened.isEmpty())
        mouse.clear()
        event(MotionEvent.ACTION_DOWN); target = "https://different.example"
        event(MotionEvent.ACTION_UP)
        assertEquals(listOf(0, 1), mouse.map { it.first }); assertTrue(opened.isEmpty())
        mouse.clear()
        event(MotionEvent.ACTION_DOWN); event(MotionEvent.ACTION_UP, 60f)
        assertEquals(listOf(0, 1), mouse.map { it.first }); assertTrue(opened.isEmpty())
    }
    @Test fun additionalPointerPreventsOpening() {
        event(MotionEvent.ACTION_DOWN)
        event(MotionEvent.ACTION_POINTER_DOWN)
        event(MotionEvent.ACTION_UP)
        assertEquals(listOf(0, 1), mouse.map { it.first }); assertTrue(opened.isEmpty())
    }
}
