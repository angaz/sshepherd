package io.angaz.sshepherd

import android.view.KeyEvent
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class TerminalKeysTest {
    @Test fun altGrPreservesLayoutCharacterAndConsumesItsModifiers() {
        val event = KeyEvent(0, 0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_Q, 0,
            KeyEvent.META_ALT_ON or KeyEvent.META_ALT_RIGHT_ON or KeyEvent.META_CTRL_ON)
        val result = TerminalKeys.resolve(event) { meta ->
            // Deterministic physical keyboard layout: RightAlt+Q -> @.
            if (meta and KeyEvent.META_ALT_RIGHT_ON != 0) '@'.code else 'q'.code
        }
        assertEquals('@'.code, result.codepoint)
        assertEquals(6, result.mods)
        assertEquals(6, result.consumedMods)
    }
    @Test fun terminalAltIsNotConsumedWhenLayoutDoesNotUseIt() {
        val event = KeyEvent(0, 0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_Q, 0, KeyEvent.META_ALT_ON or KeyEvent.META_ALT_LEFT_ON)
        val result = TerminalKeys.resolve(event) { 'q'.code }
        assertEquals('q'.code, result.codepoint)
        assertEquals(4, result.mods)
        assertEquals(0, result.consumedMods)
    }
    @Test fun shiftedPrintableTextKeepsLayoutUnicode() {
        val event = KeyEvent(0, 0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_A, 0, KeyEvent.META_SHIFT_ON)
        val result = TerminalKeys.resolve(event) { 'A'.code }
        assertEquals('A'.code, result.codepoint)
        assertEquals(1, result.consumedMods)
    }
}
