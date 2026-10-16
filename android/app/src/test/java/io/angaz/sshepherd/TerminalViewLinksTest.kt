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
    private fun mobileView(): TerminalView = TerminalView(RuntimeEnvironment.getApplication()).apply {
        onFailure = { fail(it) }
        layout(0, 0, 60, 30)
        acceptingInput = true
        feed(("\u001b[?1049h\u001b[?1000h\u001b[?1006h" +
            "\u001b[1;51H│\u001b[2;51H│ switch  \u001b[3;1HOpen example.com").toByteArray())
        val bitmap = Bitmap.createBitmap(60, 30, Bitmap.Config.ARGB_8888)
        draw(Canvas(bitmap)); draw(Canvas(bitmap)); bitmap.recycle()
    }
    private fun gesture(view: TerminalView, action: Int, time: Long, x: Float = 0.5f, y: Float = 0.5f) {
        val event = MotionEvent.obtain(10, time, action, x, y, 0)
        try { assertTrue(view.dispatchTouchEvent(event)) } finally { event.recycle() }
    }
    private fun tap(view: TerminalView) {
        gesture(view, MotionEvent.ACTION_DOWN, 10)
        gesture(view, MotionEvent.ACTION_UP, 100)
    }

    @Test fun strippedLabeledLinkUsesApiWithHeaderAdjustedCell() {
        val context = RuntimeEnvironment.getApplication()
        val view = mobileView()
        try {
            val output = mutableListOf<ByteArray>()
            view.onInput = { output.add(it); true }
            view.onLinkLookup = { request, callback ->
                assertEquals("Open example.com", request.getString("line"))
                assertEquals(0, request.getInt("row")); assertEquals(4, request.getInt("col"))
                assertEquals(60, request.getInt("cols")); assertEquals(view.rows - 2, request.getInt("rows"))
                callback(org.json.JSONObject().put("url", "https://example.com").put("handled", false))
                true
            }
            // The space inside a labeled link is part of the clickable label.
            gesture(view, MotionEvent.ACTION_DOWN, 10, 4.5f)
            gesture(view, MotionEvent.ACTION_UP, 100, 4.5f)
            assertEquals("https://example.com", shadowOf(context).nextStartedActivity?.dataString)
            assertTrue(output.isEmpty())
        } finally { view.close() }
    }

    @Test fun apiNoLinkReplaysMouseClickButErrorsPluginsAndUnsafeUrlsDoNot() {
        val context = RuntimeEnvironment.getApplication()
        for (kind in listOf("none", "error", "plugin", "unsafe")) {
            val view = mobileView()
            try {
                val output = mutableListOf<ByteArray>()
                view.onInput = { output.add(it); true }
                view.onLinkLookup = { _, callback ->
                    callback(when (kind) {
                        "none" -> org.json.JSONObject().put("fallback", true)
                        "plugin" -> org.json.JSONObject().put("url", "https://example.com").put("handled", true)
                        "unsafe" -> org.json.JSONObject().put("url", "intent://bad")
                        else -> null
                    }); true
                }
                tap(view)
                assertNull(shadowOf(context).nextStartedActivity)
                if (kind == "none") {
                    val bytes = output.flatMap { it.toList() }.toByteArray().toString(Charsets.UTF_8)
                    assertTrue(bytes.contains("M")); assertTrue(bytes.contains("m"))
                } else assertTrue(output.isEmpty())
            } finally { view.close() }
        }
    }

    @Test fun apiRepliesAfterChangedContentNewGestureOrInputPauseAreDiscarded() {
        val context = RuntimeEnvironment.getApplication()
        for (kind in listOf("content", "gesture", "pause", "close", "keyboard")) {
            val view = mobileView()
            try {
                var callback: ((org.json.JSONObject?) -> Unit)? = null
                view.onInput = { true }
                view.onLinkLookup = { _, reply -> callback = reply; true }
                tap(view)
                assertNotNull(callback)
                when (kind) {
                    "content" -> view.feed("\u001b[3;1HChanged content!".toByteArray())
                    "gesture" -> gesture(view, MotionEvent.ACTION_DOWN, 200)
                    "pause" -> { view.acceptingInput = false; view.acceptingInput = true }
                    "keyboard" -> view.sendRaw(byteArrayOf(3))
                    "close" -> view.close()
                }
                callback!!(org.json.JSONObject().put("url", "https://example.com"))
                assertNull(shadowOf(context).nextStartedActivity)
            } finally { view.close() }
        }
    }

    @Test fun dragsAndCancelledTouchesNeverCallApi() {
        val view = mobileView()
        try {
            view.onLinkLookup = { _, _ -> fail("not a link tap"); true }
            val output = mutableListOf<ByteArray>()
            view.onInput = { output.add(it); true }
            gesture(view, MotionEvent.ACTION_DOWN, 10)
            gesture(view, MotionEvent.ACTION_CANCEL, 100)
            assertTrue(output.isEmpty())
            gesture(view, MotionEvent.ACTION_DOWN, 200)
            gesture(view, MotionEvent.ACTION_MOVE, 230, 40f)
            gesture(view, MotionEvent.ACTION_UP, 250, 40f)
            assertTrue(output.isNotEmpty())
        } finally { view.close() }
    }

}
