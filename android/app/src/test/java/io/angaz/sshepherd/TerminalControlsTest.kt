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
    private fun visible(view: View): Boolean = view.visibility == View.VISIBLE &&
        ((view.parent as? View)?.let(::visible) ?: true)
    private val context get() = ContextThemeWrapper(RuntimeEnvironment.getApplication(), R.style.Theme_SSHepherd)
    private fun button(name: String) = MaterialButton(context).apply { text = name; contentDescription = name }
    private fun primary() = listOf(
        listOf("Esc", "Tab", "Home", "↑", "End", "PgUp").map(::button),
        listOf("Ctrl", "Ctrl+C", "←", "↓", "→", "PgDn").map(::button)
    )
    private fun layout(controls: TerminalControls, width: Int, height: Int = 500) {
        controls.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.AT_MOST))
        controls.layout(0, 0, controls.measuredWidth, controls.measuredHeight)
    }
    @Test fun navigationAndCtrlStayVisibleInTwoCompactRows() {
        val keys = primary()
        var clicks = 0
        keys.flatten().forEach { it.setOnClickListener { clicks++ } }
        val controls = TerminalControls(context, keys, listOf(button("Paste"))) {}
        for (width in listOf(320, 360, 720)) {
            layout(controls, width)
            assertFalse(controls.expanded)
            assertEquals(84, controls.height)
            keys.forEach { row ->
                assertEquals(1, row.map { it.top }.distinct().size)
                assertTrue(row.all { visible(it) && it.width >= 44 && it.height == 40 })
                assertTrue(row.all { it.minWidth == 0 && it.paddingLeft == 0 && it.paddingRight == 0 })
            }
            assertTrue((keys[0][0].parent as View).top < (keys[1][0].parent as View).top)
            keys.flatten().forEach { it.performClick() }
        }
        assertEquals(36, clicks)
        assertTrue(keys.flatten().all { it.tooltipText == it.contentDescription })
    }
    @Test fun controlLatchHasAVisibleCheckedState() {
        val keys = primary()
        val ctrl = keys[1][0].apply { isCheckable = true }
        val controls = TerminalControls(context, keys, emptyList()) {}
        layout(controls, 360)
        val tint = ctrl.backgroundTintList!!
        assertNotEquals(tint.defaultColor, tint.getColorForState(intArrayOf(android.R.attr.state_checked), tint.defaultColor))
        ctrl.performClick()
        assertTrue(ctrl.isChecked)
        ctrl.performClick()
        assertFalse(ctrl.isChecked)
    }
    @Test fun extraKeysExpandWithoutHorizontalScrollingAndKeyboardIsBottomRight() {
        var keyboard = 0
        val extras = (1..16).map { button("Key $it") }
        val controls = TerminalControls(context, primary(), extras) { keyboard++ }
        layout(controls, 360)
        val all = children(controls)
        assertFalse(all.any { it is HorizontalScrollView })
        val keyboardButton = all.filterIsInstance<MaterialButton>().single { it.contentDescription == "Show keyboard" }
        val expand = all.filterIsInstance<MaterialButton>().single { it.contentDescription == "Show extra keys" }
        assertEquals("", keyboardButton.text.toString())
        assertNotNull(keyboardButton.icon)
        assertTrue(keyboardButton.isFocusable)
        assertFalse(keyboardButton.isFocusableInTouchMode)
        assertTrue(keyboardButton.requestFocus())
        assertSame(expand, android.view.FocusFinder.getInstance().findNextFocus(controls, keyboardButton, View.FOCUS_UP))
        assertEquals(expand.left, keyboardButton.left)
        assertTrue((keyboardButton.parent as View).top > (expand.parent as View).top)
        keyboardButton.performClick()
        assertEquals(1, keyboard)
        expand.performClick(); layout(controls, 360)
        assertTrue(controls.expanded)
        assertEquals("Hide extra keys", expand.contentDescription)
        assertEquals(expand.contentDescription, expand.tooltipText)
        assertEquals(4, extras.map { it.top }.distinct().size)
        assertTrue(extras.all { it.width >= 48 && it.right <= 352 })
        layout(controls, 720)
        assertEquals(2, extras.map { it.top }.distinct().size)
        layout(controls, 360, 220)
        val panel = extras[0].parent.parent as View
        assertTrue(panel.height <= 100)
        assertTrue(visible(keyboardButton))
        expand.performClick(); layout(controls, 360)
        assertFalse(controls.expanded)
        assertEquals("Show extra keys", expand.tooltipText)
        assertEquals(84, controls.height)
        assertTrue(extras.none(::visible))
    }
}
