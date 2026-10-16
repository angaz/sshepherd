package io.angaz.sshepherd

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.MotionEvent
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Exercise the actual Canvas view and host JNI engine, not a fake link resolver. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class TerminalViewLinksTest {
    @Test fun labeledLinkOpensThroughNativeGridAndRealTouchDispatch() {
        val context = RuntimeEnvironment.getApplication()
        val view = TerminalView(context)
        try {
            view.onFailure = { fail(it) }
            view.onMessage = { fail(it) }
            view.layout(0, 0, 400, 600)
            view.acceptingInput = true
            val output = mutableListOf<ByteArray>()
            view.onInput = { output.add(it); true }
            view.feed("\u001b[?1049h\u001b[?1000h\u001b[?1006h\u001b[?2026h\u001b[H\u001b]8;;https://example.com\u001b\\Open example.com\u001b]8;;\u001b\\\u001b[?2026l".toByteArray())
            val bitmap = Bitmap.createBitmap(400, 600, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            bitmap.recycle()
            val x = TerminalView::class.java.getDeclaredField("cellWidth").apply { isAccessible = true }.getInt(view) * 0.5f
            val y = TerminalView::class.java.getDeclaredField("cellHeight").apply { isAccessible = true }.getInt(view) * 0.5f
            for ((action, time) in listOf(MotionEvent.ACTION_DOWN to 10L, MotionEvent.ACTION_UP to 100L)) {
                val event = MotionEvent.obtain(10, time, action, x, y, 0)
                try { assertTrue(view.dispatchTouchEvent(event)) } finally { event.recycle() }
            }
            assertEquals("https://example.com", shadowOf(context).nextStartedActivity?.dataString)
            assertTrue(output.isEmpty())
        } finally { view.close() }
    }
}
