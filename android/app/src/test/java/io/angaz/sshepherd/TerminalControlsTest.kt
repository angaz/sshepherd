package io.angaz.sshepherd

import android.view.ContextThemeWrapper
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import com.google.android.material.button.MaterialButton
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], qualifiers = "mdpi")
class TerminalControlsTest {
    private fun children(view: View): List<View> = listOf(view) + if (view is ViewGroup)
        (0 until view.childCount).flatMap { children(view.getChildAt(it)) } else emptyList()
    @Test fun extraKeysExpandWithoutHorizontalScrollingAndKeyboardIsBottomRight() {
        val context = ContextThemeWrapper(RuntimeEnvironment.getApplication(), R.style.Theme_SSHepherd)
        var keyboard = 0
        fun button(name: String) = MaterialButton(context).apply { text = name }
        val extras = (1..16).map { button("Key $it") }
        val controls = TerminalControls(context, listOf(button("Esc"), button("Tab"), button("Ctrl+C")), extras) { keyboard++ }
        fun layout(width: Int) {
            controls.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(500, View.MeasureSpec.AT_MOST))
            controls.layout(0, 0, controls.measuredWidth, controls.measuredHeight)
        }
        layout(360)
        val all = children(controls)
        assertFalse(all.any { it is HorizontalScrollView })
        val keyboardButton = all.filterIsInstance<MaterialButton>().single { it.contentDescription == "Show keyboard" }
        val expand = all.filterIsInstance<MaterialButton>().single { it.contentDescription == "Show extra keys" }
        assertEquals("", keyboardButton.text.toString())
        assertNotNull(keyboardButton.icon)
        assertTrue(keyboardButton.isFocusable)
        assertFalse(keyboardButton.isFocusableInTouchMode)
        assertTrue(expand.requestFocus())
        assertSame(keyboardButton, android.view.FocusFinder.getInstance().findNextFocus(controls, expand, View.FOCUS_RIGHT))
        assertTrue(keyboardButton.left > expand.left)
        assertTrue(keyboardButton.width >= 48 && keyboardButton.height >= 48)
        keyboardButton.performClick()
        assertEquals(1, keyboard)
        expand.performClick(); layout(360)
        assertTrue(controls.expanded)
        assertEquals("Hide extra keys", expand.contentDescription)
        assertEquals(4, extras.map { it.top }.distinct().size)
        assertTrue(extras.all { it.width >= 48 && it.right <= 348 })
        layout(720)
        assertEquals(2, extras.map { it.top }.distinct().size)
        expand.performClick(); layout(360)
        assertFalse(controls.expanded)
        assertTrue(controls.height < 80)
    }
}
