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
    @Test fun screenshotsAndAppPreviewsAreNotBlocked() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        assertEquals(0, controller.get().window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE)
        controller.pause().stop().destroy()
    }
    @Test fun nativeServerInventoryExistsWithoutNetworkOrCredentials() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        val views = children(activity.window.decorView)
        val buttons = views.filterIsInstance<Button>().map { it.text.toString() }
        for (host in listOf("host-a", "host-b", "host-c", "host-d", "host-e", "host-f")) {
            assertTrue("Missing $host", buttons.any { it.startsWith("$host\n") })
        }
        assertFalse(views.any { it.javaClass.name.contains("WebView") })
        controller.pause().stop().destroy()
    }
}
