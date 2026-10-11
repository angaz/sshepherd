package io.angaz.sshepherd

import android.view.View
import android.view.ViewGroup
import com.google.android.material.appbar.MaterialToolbar
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class ScratchpadScreenTest {
    @Test fun snapshotIsEditableSelectableAndLateResponsesCannotOverwriteEdits() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup()
        var backs = 0
        val screen = ScratchpadScreen(activity.get(), {}, { backs++ })
        activity.get().setContentView(screen)
        assertFalse(screen.editor.isEnabled)
        screen.display(ScrollbackSnapshot("p1", "hello 🐑\nworld", true))
        assertTrue(screen.editor.isEnabled)
        assertFalse(screen.editor.showSoftInputOnFocus)
        assertFalse(screen.editor.isSaveEnabled)
        screen.editor.setSelection(0, 5)
        assertTrue(screen.editor.onTextContextMenuItem(android.R.id.copy))
        val clipboard = activity.get().getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        assertEquals("hello", clipboard.primaryClip!!.getItemAt(0).text.toString())
        screen.editor.text.replace(0, 5, "edited")
        assertTrue(screen.hasEdits)
        screen.display(ScrollbackSnapshot("p2", "replacement", false))
        screen.error("Disconnected")
        assertEquals("edited 🐑\nworld", screen.editor.text.toString())
        val toolbar = screen.getChildAt(0) as MaterialToolbar
        assertFalse(toolbar.menu.findItem(1).isVisible)
        toolbar.menu.performIdentifierAction(2, 0)
        assertTrue(screen.editor.showSoftInputOnFocus)
        activity.pause().stop().destroy()
    }
    @Test fun snapshotDecoderRejectsOversizeText() {
        val record = JSONObject().put("pane_id", "p1").put("text", "🐑").put("truncated", false)
        assertEquals("🐑", ScrollbackSnapshot.decode(record).text)
        record.put("text", "x".repeat(256 * 1024 + 1))
        assertThrows(IllegalArgumentException::class.java) { ScrollbackSnapshot.decode(record) }
    }
    @Test fun overlayPausesTerminalSceneAndBackConfirmsDiscardWithoutSendingEdits() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        fun field(name: String) = MainActivity::class.java.getDeclaredField(name).apply { isAccessible = true }
        fun call(name: String, vararg args: Any?) = MainActivity::class.java.declaredMethods.single { it.name == name }
            .apply { isAccessible = true }.invoke(activity, *args)
        val root = field("root").get(activity) as android.widget.FrameLayout
        val scene = root.getChildAt(0) as ViewGroup
        field("terminalContent").set(activity, scene)
        val screen = ScratchpadScreen(activity, {}, { activity.onBackPressedDispatcher.onBackPressed() })
        call("openScratchpadScreen", screen)
        assertEquals(View.INVISIBLE, scene.visibility)
        field("workspaceRequest").set(activity, "capture")
        field("workspaceAction").set(activity, "scrollback")
        call("receiveWorkspaces", """{"id":"capture","scrollback":{"pane_id":"p1","text":"hello","truncated":false}}""")
        assertEquals("hello", screen.editor.text.toString())
        screen.editor.append(" edited")
        activity.onBackPressedDispatcher.onBackPressed()
        val dialog = org.robolectric.shadows.ShadowDialog.getLatestDialog() as androidx.appcompat.app.AlertDialog
        assertSame(root, screen.parent)
        dialog.getButton(androidx.appcompat.app.AlertDialog.BUTTON_NEGATIVE).performClick()
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertSame(root, screen.parent)
        activity.onBackPressedDispatcher.onBackPressed()
        (org.robolectric.shadows.ShadowDialog.getLatestDialog() as androidx.appcompat.app.AlertDialog)
            .getButton(androidx.appcompat.app.AlertDialog.BUTTON_POSITIVE).performClick()
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertNull(screen.parent)
        assertEquals(View.VISIBLE, scene.visibility)
        assertTrue((field("outbound").get(activity) as java.util.ArrayDeque<*>).isEmpty())
        controller.pause().stop().destroy()
    }
}
