package io.angaz.sshepherd

import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class MainActivityTest {
    private fun children(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { children(view.getChildAt(it)) } else emptyList()
    @Test fun suppliedAdaptiveLauncherIconsLoad() {
        val app = org.robolectric.RuntimeEnvironment.getApplication()
        assertTrue(app.applicationInfo.icon in listOf(R.mipmap.ic_launcher, R.mipmap.ic_launcher_round))
        for (id in listOf(R.mipmap.ic_launcher, R.mipmap.ic_launcher_round)) {
            val adaptive = app.getDrawable(id) as android.graphics.drawable.AdaptiveIconDrawable
            assertNotNull(adaptive.background)
            val foreground = adaptive.foreground as android.graphics.drawable.InsetDrawable
            foreground.setBounds(0, 0, 1000, 1000)
            assertEquals(android.graphics.Rect(120, 120, 880, 880), foreground.drawable!!.bounds)
        }
    }
    @Test fun hostsCanBeAddedRenamedAndDeletedThroughMaterialDialogs() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        val bar = children(activity.window.decorView).filterIsInstance<com.google.android.material.appbar.MaterialToolbar>().single()
        bar.menu.performIdentifierAction(1, 0)
        fun dialog(): androidx.appcompat.app.AlertDialog {
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
            return org.robolectric.shadows.ShadowDialog.getLatestDialog() as androidx.appcompat.app.AlertDialog
        }
        dialog().findViewById<android.widget.EditText>(R.id.host_name)!!.setText("Office PC")
        dialog().findViewById<android.widget.EditText>(R.id.host_address)!!.setText("192.0.2.10")
        dialog().getButton(androidx.appcompat.app.AlertDialog.BUTTON_POSITIVE).performClick()
        assertTrue(HostStore(activity).read().any { it.name == "Office PC" && it.address == "192.0.2.10" })
        children(activity.window.decorView).single { it.contentDescription == "Edit Office PC" }.performClick()
        dialog().findViewById<android.widget.EditText>(R.id.host_name)!!.setText("My desktop")
        dialog().getButton(androidx.appcompat.app.AlertDialog.BUTTON_POSITIVE).performClick()
        assertTrue(HostStore(activity).read().any { it.name == "My desktop" })
        children(activity.window.decorView).single { it.contentDescription == "Edit My desktop" }.performClick()
        dialog().getButton(androidx.appcompat.app.AlertDialog.BUTTON_NEUTRAL).performClick()
        dialog().getButton(androidx.appcompat.app.AlertDialog.BUTTON_POSITIVE).performClick()
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertFalse(HostStore(activity).read().any { it.name == "My desktop" })
        controller.pause().stop().destroy()
    }
    @Test fun screenshotsAndAppPreviewsAreNotBlocked() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        assertEquals(0, controller.get().window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE)
        controller.pause().stop().destroy()
    }
    @Test fun nativeServerInventoryExistsWithoutNetworkOrCredentials() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        val views = children(activity.window.decorView)
        val cards = views.filterIsInstance<com.google.android.material.card.MaterialCardView>()
        for (host in listOf("host-a", "host-b", "host-c", "host-d", "host-e", "host-f")) {
            assertTrue("Missing $host", cards.any { it.contentDescription.toString().startsWith("$host.") })
        }
        assertFalse(views.any { it.javaClass.name.contains("WebView") })
        assertFalse(views.any { it is android.widget.HorizontalScrollView })
        assertFalse(views.filterIsInstance<android.widget.TextView>().any { it.text.contains("Tap to connect") })
        val card = cards.first()
        val density = activity.resources.displayMetrics.density
        card.measure(View.MeasureSpec.makeMeasureSpec((360 * density).toInt(), View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec((200 * density).toInt(), View.MeasureSpec.AT_MOST))
        card.layout(0, 0, card.measuredWidth, card.measuredHeight)
        assertTrue(card.measuredHeight <= 80 * density)
        val labels = children(card).filterIsInstance<android.widget.TextView>()
        assertTrue(labels.single { it.text == "host-a.example.invalid" }.left > labels.single { it.text == "host-a" }.left)
        assertTrue(views.any { it is com.google.android.material.appbar.MaterialToolbar })
        controller.pause().stop().destroy()
    }
}
