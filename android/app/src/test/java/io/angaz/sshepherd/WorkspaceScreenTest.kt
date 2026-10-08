package io.angaz.sshepherd

import android.view.View
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.appbar.MaterialToolbar
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], qualifiers = "mdpi")
class WorkspaceScreenTest {
    private fun children(view: View): List<View> = listOf(view) + if (view is ViewGroup)
        (0 until view.childCount).flatMap { children(view.getChildAt(it)) } else emptyList()
    private fun layout(view: View, width: Int, height: Int) {
        view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        view.layout(0, 0, width, height)
    }
    @Test fun nativeScreenUsesRemainingHeightWithoutAModalAndKeepsActionsUsable() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup()
        var refreshed = 0
        var back = 0
        val selected = mutableListOf<DirectoryRow>()
        val screen = WorkspaceScreen(activity.get(), { refreshed++ }, { selected.add(it) }, { back++ })
        activity.get().setContentView(screen)
        val list = children(screen).filterIsInstance<RecyclerView>().single()
        val toolbar = children(screen).filterIsInstance<MaterialToolbar>().single()
        assertNull(ShadowDialog.getLatestDialog())
        val rows = (1..300).map { DirectoryRow("w$it", "Workspace $it", "2 panes", false) }
        screen.display(rows)
        layout(screen, 400, 800)
        val portraitHeight = list.height
        assertTrue(portraitHeight > 600)
        assertTrue(list.childCount < rows.size)
        layout(screen, 400, 1200)
        assertEquals(portraitHeight + 400, list.height)
        layout(screen, 720, 320)
        assertTrue(list.height > 0)
        assertEquals(300, list.adapter!!.itemCount)
        toolbar.menu.performIdentifierAction(1, 0)
        assertEquals(1, refreshed)
        screen.loading("Loading…")
        assertFalse(toolbar.menu.findItem(1).isEnabled)
        list.findViewHolderForAdapterPosition(0)?.itemView?.performClick()
        assertTrue(selected.isEmpty())
        screen.error("Disconnected")
        assertEquals(0, list.adapter!!.itemCount)
        assertTrue(toolbar.menu.findItem(1).isEnabled)
        screen.display(rows.take(1))
        layout(screen, 400, 800)
        list.findViewHolderForAdapterPosition(0)!!.itemView.performClick()
        assertEquals(rows.take(1), selected)
        children(toolbar).single { it.contentDescription == "Back to terminal" }.performClick()
        assertEquals(1, back)
        activity.pause().stop().destroy()
    }
}
