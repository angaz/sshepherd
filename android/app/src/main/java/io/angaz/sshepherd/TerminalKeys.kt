package io.angaz.sshepherd

import android.view.KeyCharacterMap
import android.view.KeyEvent

internal data class EncodedKeyText(val codepoint: Int, val mods: Int, val consumedMods: Int)
internal object TerminalKeys {
    /** Preserve layout-selected Alt/AltGr text; distinguish it from terminal Alt.
     * The injected lookup makes real KeyCharacterMap selection policy testable.
     */
    fun resolve(event: KeyEvent, lookup: (Int) -> Int = event::getUnicodeChar): EncodedKeyText {
        val noCtrl = event.metaState and KeyEvent.META_CTRL_MASK.inv()
        val noAlt = noCtrl and KeyEvent.META_ALT_MASK.inv()
        val layout = lookup(noCtrl)
        val base = lookup(noAlt)
        val mods = (if (event.isShiftPressed) 1 else 0) or (if (event.isCtrlPressed) 2 else 0) or
            (if (event.isAltPressed) 4 else 0) or (if (event.isMetaPressed) 8 else 0)
        var consumed = 0
        val layoutIsText = layout >= 32 || layout and KeyCharacterMap.COMBINING_ACCENT != 0
        val altSelectedText = event.isAltPressed && layout != base && layoutIsText
        if (altSelectedText) {
            consumed = consumed or 4
            // Some physical layouts represent AltGr as Ctrl+RightAlt.
            if (event.metaState and KeyEvent.META_ALT_RIGHT_ON != 0 && event.isCtrlPressed) consumed = consumed or 2
        }
        val point = if (altSelectedText || !event.isAltPressed) layout else base
        if (event.isShiftPressed && point >= 32) consumed = consumed or 1
        return EncodedKeyText(point, mods, consumed)
    }
}
