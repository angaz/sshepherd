package io.angaz.sshepherd

/** Recognize Herdr's rendered mobile chrome, not arbitrary VT escape sequences. */
internal object TerminalViewport {
    fun hasMobileHeader(frame: TerminalFrame): Boolean {
        if (frame.cols < 12 || frame.rows < 2) return false
        val x = frame.cols - 10
        fun cell(row: Int, col: Int) = frame.cells[row * frame.cols + col]
        if (cell(0, x).text != "│" || cell(1, x).text != "│") return false
        if ((x + 1 until frame.cols - 1).any { cell(0, it).text.isNotBlank() }) return false
        if (cell(1, x + 1).text.isNotBlank() || cell(1, x + 8).text.isNotBlank()) return false
        if ((x + 2..x + 7).joinToString("") { cell(1, it).text } != "switch") return false
        val background = cell(0, x + 1).background
        return (x + 1 until frame.cols - 1).all {
            cell(0, it).background == background && cell(1, it).background == background
        }
    }
    fun remoteRows(visibleRows: Int, headerRows: Int): Int =
        visibleRows.coerceIn(2, 300 - headerRows) + headerRows
    fun paneY(remoteRow: Int, headerRows: Int, cellHeight: Int): Float =
        ((remoteRow - headerRows) * cellHeight).toFloat()
    // Keep all rows of a replacement overlay visible without oscillating PTY
    // geometry while Herdr is painting. Ordinary pane rendering stays 1:1.
    fun overlayScale(viewportHeight: Int, remoteRows: Int, cellHeight: Int): Float =
        (viewportHeight.toFloat() / (remoteRows * cellHeight)).coerceIn(0.001f, 1f)
    fun remoteY(paneY: Float, headerRows: Int, cellHeight: Int, scale: Float = 1f): Double =
        paneY.toDouble() / scale + headerRows * cellHeight
}
