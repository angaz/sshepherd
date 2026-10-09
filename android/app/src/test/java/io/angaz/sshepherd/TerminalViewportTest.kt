package io.angaz.sshepherd

import org.junit.Assert.*
import org.junit.Test

class TerminalViewportTest {
    private fun frame(header: Boolean, cols: Int = 40): TerminalFrame {
        val cells = MutableList(cols * 24) { TerminalCell(1, 0, 0xffeeeeee.toInt(), 0xff10141c.toInt(), "") }
        if (header) {
            val x = cols - 10
            for (row in 0..1) for (col in x until cols) {
                cells[row * cols + col] = cells[row * cols + col].copy(background = 0xff252529.toInt())
            }
            for (row in 0..1) cells[row * cols + x] = cells[row * cols + x].copy(text = "│")
            "switch".forEachIndexed { i, char -> cells[cols + x + 2 + i] = cells[cols + x + 2 + i].copy(text = char.toString()) }
            cells[cols * 2 - 1] = cells[cols * 2 - 1].copy(text = "!") // blocked indicator
        }
        return TerminalFrame(cols, 24, 0, 5, 0, 1, 0, 0, 0, cells)
    }
    @Test fun recognizesTheActualHeaderSignatureAtDifferentWidths() {
        assertTrue(TerminalViewport.hasMobileHeader(frame(true, 40)))
        assertTrue(TerminalViewport.hasMobileHeader(frame(true, 90)))
    }
    @Test fun ordinaryTerminalTextAndPartialHeaderDoNotTriggerCropping() {
        val plain = frame(false)
        assertFalse(TerminalViewport.hasMobileHeader(plain))
        val cells = plain.cells.toMutableList()
        "switch".forEachIndexed { i, c -> cells[40 + 30 + 2 + i] = cells[40 + 30 + 2 + i].copy(text = c.toString()) }
        assertFalse(TerminalViewport.hasMobileHeader(plain.copy(cells = cells)))
        val incomplete = frame(true).cells.toMutableList()
        incomplete[30] = incomplete[30].copy(text = "")
        assertFalse(TerminalViewport.hasMobileHeader(plain.copy(cells = incomplete)))
    }
    @Test fun replacementOverlaysKeepTheirFirstAndLastRowsAndMouseAlignment() {
        assertTrue(TerminalViewport.hasMobileHeader(frame(true)))
        val overlay = frame(false)
        assertFalse(TerminalViewport.hasMobileHeader(overlay))
        // Retain the extra PTY rows, but do not crop a headerless replacement.
        val remoteRows = TerminalViewport.remoteRows(24, 2)
        val scale = TerminalViewport.overlayScale(24 * 18, remoteRows, 18)
        assertEquals(24f / 26, scale, 0.00001f)
        assertEquals(0f, TerminalViewport.paneY(0, 0, 18) * scale, 0f)
        assertEquals(432f, remoteRows * 18 * scale, 0.0001f)
        for (row in listOf(0, 25)) {
            val paneY = TerminalViewport.paneY(row, 0, 18) * scale
            assertEquals(row * 18.0, TerminalViewport.remoteY(paneY, 0, 18, scale), 0.0001)
        }
        assertTrue(TerminalViewport.hasMobileHeader(frame(true))) // returning restores normal crop
    }
    @Test fun extraRemoteRowsPreserveAllPaneRowsAndCursorMouseCoordinatesAgree() {
        assertEquals(24, TerminalViewport.remoteRows(24, 0))
        assertEquals(26, TerminalViewport.remoteRows(24, 2))
        assertEquals(300, TerminalViewport.remoteRows(400, 2))
        assertEquals(4, TerminalViewport.remoteRows(0, 2))
        assertEquals(0f, TerminalViewport.paneY(2, 2, 18), 0f)
        assertEquals(54f, TerminalViewport.paneY(5, 2, 18), 0f)
        assertEquals(36.0, TerminalViewport.remoteY(0f, 2, 18), 0.0)
        assertEquals(90.0, TerminalViewport.remoteY(TerminalViewport.paneY(5, 2, 18), 2, 18), 0.0)
    }
}
