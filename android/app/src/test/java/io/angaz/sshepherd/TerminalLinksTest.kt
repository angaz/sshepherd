package io.angaz.sshepherd

import android.content.ActivityNotFoundException
import android.content.ContextWrapper
import android.content.Intent
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class TerminalLinksTest {
    private fun frame(text: String, cols: Int = 80, wraps: Set<Int> = emptySet()): TerminalFrame {
        val cells = MutableList(cols * 4) { TerminalCell(1, 0, 0, 0, "") }
        text.take(cells.size).forEachIndexed { i, c -> cells[i] = cells[i].copy(text = c.toString()) }
        for (row in wraps) for (col in 0 until cols) cells[row * cols + col] = cells[row * cols + col].copy(flags = 128)
        return TerminalFrame(cols, 4, 0, 0, 0, 0, 0, 0, 0, cells)
    }
    @Test fun onlyTappedWebTextOpensAndProsePunctuationIsExcluded() {
        val text = "See (https://example.com/a_(b)?x=1#anchor). Next www.example.org!"
        val frame = frame(text)
        assertEquals("https://example.com/a_(b)?x=1#anchor", TerminalLinks.at(frame, 12, 0))
        assertEquals("https://www.example.org", TerminalLinks.at(frame, text.indexOf("www"), 0))
        for (col in listOf(0, 4, text.indexOf("). Next") + 1, 79, -1, 80)) assertNull(TerminalLinks.at(frame, col, 0))
    }
    @Test fun softWrappedLinksJoinButHardNewlinesDoNot() {
        val text = "https://example.com/long/path?x=1"
        val wrapped = frame(text, 20, setOf(0))
        assertEquals(text, TerminalLinks.at(wrapped, 5, 1))
        assertEquals(text, TerminalLinks.at(wrapped, 5, 0))
        val hardBreak = frame(text, 20)
        assertEquals(text.take(20), TerminalLinks.at(hardBreak, 5, 0))
        assertNull(TerminalLinks.at(hardBreak, 5, 1))
    }
    @Test fun unicodeGraphemesWideCellsAndInvisibleCellsKeepHitTestingAligned() {
        val base = frame("  https://example.com/café")
        val cells = base.cells.toMutableList()
        cells[0] = cells[0].copy(width = 2, text = "🐑")
        cells[1] = cells[1].copy(width = 0, text = "")
        cells[24] = cells[24].copy(text = "e\u0301")
        val unicode = base.copy(cells = cells)
        assertEquals("https://example.com/cae\u0301é", TerminalLinks.at(unicode, 24, 0))
        assertNull(TerminalLinks.at(unicode, 1, 0))
        val hidden = frame("https://example.com").let { f -> f.copy(cells = f.cells.map { it.copy(flags = 16) }) }
        assertNull(TerminalLinks.at(hidden, 5, 0))
    }
    @Test fun rejectsUnsafeSchemesMalformedAndOversizedUrls() {
        for (url in listOf("javascript:alert(1)", "intent://example.com", "file:///tmp/test", "content://example.com",
            "https://", "https://user@example.com", "https://example.com/\n", "https://example.com/\u0000", "https://example.com/" + "a".repeat(8192))) {
            assertNull(url, TerminalLinks.webUrl(url))
        }
        assertEquals("https://example.com/", TerminalLinks.webUrl("HTTPS://example.com/"))
        assertEquals("http://localhost:8080/a", TerminalLinks.webUrl("http://localhost:8080/a"))
        assertEquals("https://[fd00::1]/", TerminalLinks.webUrl("https://[fd00::1]/"))
    }
    @Test fun opensBrowsableViewIntentAndHandlesMissingBrowser() {
        val context = RuntimeEnvironment.getApplication()
        TerminalLinks.open(context, "https://example.com/", { fail(it) })
        val intent = shadowOf(context).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertTrue(intent.hasCategory(Intent.CATEGORY_BROWSABLE))
        assertEquals("https://example.com/", intent.dataString)
        TerminalLinks.open(context, "intent://example.com", { fail(it) })
        assertNull(shadowOf(context).nextStartedActivity)
        val noBrowser = object : ContextWrapper(context) {
            override fun startActivity(intent: Intent) { throw ActivityNotFoundException() }
        }
        var message = ""
        TerminalLinks.open(noBrowser, "https://example.com", { message = it })
        assertTrue(message.contains("No app"))
    }
}
