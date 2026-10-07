package io.angaz.sshepherd

import android.view.View
import android.view.ViewGroup
import androidx.appcompat.app.AlertDialog
import androidx.recyclerview.widget.RecyclerView
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class WorkspaceDialogTest {
    private fun children(view: View): List<View> = listOf(view) + if (view is ViewGroup)
        (0 until view.childCount).flatMap { children(view.getChildAt(it)) } else emptyList()
    @Test fun nativeListRefreshLoadingErrorAndCloseAreUsable() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup()
        var refreshed = 0
        var closed = 0
        val selected = mutableListOf<DirectoryRow>()
        val picker = WorkspaceDialog(activity.get(), { refreshed++ }, { selected.add(it) }, { closed++ })
        picker.show()
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        val dialog = ShadowDialog.getLatestDialog() as AlertDialog
        val list = children(dialog.window!!.decorView).filterIsInstance<RecyclerView>().single()
        val rows = (1..300).map { DirectoryRow("w$it", "Workspace $it", "2 panes", false) }
        picker.display(rows)
        assertEquals(300, list.adapter!!.itemCount)
        assertEquals(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN,
            dialog.window!!.attributes.softInputMode and android.view.WindowManager.LayoutParams.SOFT_INPUT_MASK_STATE)
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).performClick()
        assertEquals(1, refreshed)
        picker.loading("Loading…")
        assertFalse(dialog.getButton(AlertDialog.BUTTON_NEUTRAL).isEnabled)
        picker.error("Disconnected")
        assertEquals(0, list.adapter!!.itemCount)
        assertTrue(dialog.getButton(AlertDialog.BUTTON_NEUTRAL).isEnabled)
        picker.display(rows.take(1))
        list.measure(View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(200, View.MeasureSpec.EXACTLY))
        list.layout(0, 0, 400, 200)
        list.findViewHolderForAdapterPosition(0)!!.itemView.performClick()
        assertEquals(rows.take(1), selected)
        picker.dismiss()
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals(1, closed)
        activity.pause().stop().destroy()
    }
}
