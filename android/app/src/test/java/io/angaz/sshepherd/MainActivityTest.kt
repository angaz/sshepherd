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
    @Test fun linkRepliesAreRequestScopedAndNeverTreatedAsDirectorySelections() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        fun field(name: String) = MainActivity::class.java.getDeclaredField(name).apply { isAccessible = true }
        fun receive(data: String) = MainActivity::class.java.getDeclaredMethod("receiveWorkspaces", String::class.java)
            .apply { isAccessible = true }.invoke(activity, data)
        var result: org.json.JSONObject? = null
        val callback: (org.json.JSONObject?) -> Unit = { result = it }
        field("workspaceRequest").set(activity, "link-1")
        field("workspaceAction").set(activity, "link")
        field("linkCallback").set(activity, callback)
        receive("""{"id":"older","link":{"url":"https://wrong.example"}}""")
        assertNull(result); assertEquals("link-1", field("workspaceRequest").get(activity))
        receive("""{"id":"link-1","link":{"url":"https://example.com","handled":false}}""")
        assertEquals("https://example.com", result?.getString("url"))
        assertNull(field("workspaceRequest").get(activity)); assertNull(field("linkCallback").get(activity))
        result = null
        receive("""{"id":"link-1","link":{"url":"https://duplicate.example"}}""")
        assertNull(result)
        field("workspaceRequest").set(activity, "link-2")
        field("workspaceAction").set(activity, "link")
        field("linkCallback").set(activity, callback)
        receive("""{"id":"link-2","error":"Stale content"}""")
        assertNull(result); assertNull(field("linkCallback").get(activity))
        controller.pause().stop().destroy()
    }
    @Test fun leavingScreenOrUncertainReplyKeepsSelectionGuardUntilConfirmation() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        fun field(name: String) = MainActivity::class.java.getDeclaredField(name).apply { isAccessible = true }
        fun call(name: String, vararg args: Any?) = MainActivity::class.java.declaredMethods.single { it.name == name }
            .apply { isAccessible = true }.invoke(activity, *args)
        val request = field("workspaceRequest")
        val selecting = field("workspaceSelecting")
        request.set(activity, "pick"); selecting.setBoolean(activity, true)
        call("closeWorkspaces")
        assertEquals("pick", request.get(activity)); assertTrue(selecting.getBoolean(activity))
        call("receiveWorkspaces", """{"id":"old","selected":true}""")
        assertTrue(selecting.getBoolean(activity))
        call("receiveWorkspaces", """{"id":"pick","error":"Timed out","uncertain":true}""")
        assertEquals("pick", request.get(activity)); assertTrue(selecting.getBoolean(activity))
        call("receiveWorkspaces", """{"id":"pick"}""")
        assertEquals("pick", request.get(activity)); assertTrue(selecting.getBoolean(activity))
        call("receiveWorkspaces", """{"id":"pick","selected":true}""")
        assertNull(request.get(activity)); assertFalse(selecting.getBoolean(activity))
        request.set(activity, "list")
        call("closeWorkspaces")
        assertEquals("list", request.get(activity))
        call("receiveWorkspaces", """{"id":"list","workspaces":[],"agents":[]}""")
        assertNull(request.get(activity))
        controller.pause().stop().destroy()
    }
    @Test fun creationIsSerializedAndReturningFromPickerDiscardsLateProjectList() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        fun field(name: String) = MainActivity::class.java.getDeclaredField(name).apply { isAccessible = true }
        fun call(name: String, vararg args: Any?) = MainActivity::class.java.declaredMethods.single { it.name == name }
            .apply { isAccessible = true }.invoke(activity, *args)
        field("phase").set(activity, "connected")
        val screen = WorkspaceScreen(activity, {}, {}, {})
        call("openWorkspaceScreen", screen)
        screen.projectMode(true)
        call("requestWorkspaces", org.json.JSONObject().put("action", "projects"))
        val pending = field("workspaceRequest").get(activity) as String
        call("backFromWorkspaces")
        assertFalse(screen.isProjectPicker)
        assertEquals(pending, field("workspaceRequest").get(activity))
        call("receiveWorkspaces", """{"id":"$pending","projects":["Empty (~)"]}""")
        assertEquals("list", field("workspaceAction").get(activity))
        val listRequest = field("workspaceRequest").get(activity) as String
        call("receiveWorkspaces", """{"id":"$listRequest","workspaces":[],"agents":[]}""")
        screen.projectMode(true)
        val create = org.json.JSONObject().put("action", "create").put("project", "Empty (~)")
        call("requestWorkspaces", create)
        val creation = field("workspaceRequest").get(activity)
        assertTrue(field("workspaceSelecting").getBoolean(activity))
        call("requestWorkspaces", create)
        assertEquals(creation, field("workspaceRequest").get(activity))
        call("backFromWorkspaces")
        assertNull(field("workspaceScreen").get(activity))
        assertTrue(field("workspaceSelecting").getBoolean(activity))
        call("receiveWorkspaces", """{"id":"$creation","error":"Timed out","uncertain":true}""")
        assertEquals(creation, field("workspaceRequest").get(activity))
        call("receiveWorkspaces", """{"id":"$creation","selected":true}""")
        assertFalse(field("workspaceSelecting").getBoolean(activity))
        controller.pause().stop().destroy()
    }
    @Test fun fullScreenNavigationHidesImeKeepsSceneMountedAndBackRestoresIt() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        fun field(name: String) = MainActivity::class.java.getDeclaredField(name).apply { isAccessible = true }
        val root = field("root").get(activity) as android.widget.FrameLayout
        val scene = root.getChildAt(0) as ViewGroup
        field("terminalContent").set(activity, scene)
        val editor = android.widget.EditText(activity)
        scene.addView(editor); editor.requestFocus()
        val ime = activity.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
        ime.showSoftInput(editor, 0)
        assertTrue(org.robolectric.Shadows.shadowOf(ime).isSoftInputVisible)
        val screen = WorkspaceScreen(activity, {}, {}, { activity.onBackPressedDispatcher.onBackPressed() })
        MainActivity::class.java.getDeclaredMethod("openWorkspaceScreen", WorkspaceScreen::class.java)
            .apply { isAccessible = true }.invoke(activity, screen)
        assertSame(root, scene.parent)
        assertEquals(View.INVISIBLE, scene.visibility)
        assertSame(root, screen.parent)
        assertEquals(-1, screen.layoutParams.width); assertEquals(-1, screen.layoutParams.height)
        assertFalse(org.robolectric.Shadows.shadowOf(ime).isSoftInputVisible)
        activity.onBackPressedDispatcher.onBackPressed()
        assertNull(screen.parent)
        assertSame(root, scene.parent)
        assertEquals(View.VISIBLE, scene.visibility)
        assertNull(field("workspaceScreen").get(activity))
        assertFalse(org.robolectric.Shadows.shadowOf(ime).isSoftInputVisible)
        controller.pause().stop().destroy()
    }
    @Test fun summaryUsesNativeStatusAndSerializesWithInteractiveList() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        fun field(name: String) = MainActivity::class.java.getDeclaredField(name).apply { isAccessible = true }
        fun call(name: String, vararg args: Any?) = MainActivity::class.java.declaredMethods.single { it.name == name }
            .apply { isAccessible = true }.invoke(activity, *args)
        val notice = android.widget.TextView(activity)
        field("notice").set(activity, notice)
        field("phase").set(activity, "connected")
        field("activeHost").set(activity, HostEntry("fixture", "Fixture", "192.0.2.1"))
        call("setNotice", "Connected", false)
        call("requestWorkspaces", org.json.JSONObject().put("action", "summary"))
        val id = field("workspaceRequest").get(activity) as String
        assertEquals("summary", field("workspaceAction").get(activity))
        assertFalse(field("workspaceSelecting").getBoolean(activity))
        val counts = """{"working":1,"blocked":0,"idle":13,"done":0,"unknown":0}"""
        call("receiveWorkspaces", """{"id":"old","summary":$counts}""")
        assertEquals("Connected", notice.text.toString())
        call("receiveWorkspaces", """{"id":"$id","summary":$counts}""")
        assertEquals("Connected · 1 working · 13 idle", notice.text.toString())
        assertNull(field("workspaceRequest").get(activity))
        call("setNotice", "Input paused", true)
        assertEquals("Input paused", notice.text.toString())
        call("setNotice", "Connected", false)
        call("requestWorkspaces", org.json.JSONObject().put("action", "summary"))
        val pending = field("workspaceRequest").get(activity) as String
        val screen = WorkspaceScreen(activity, {}, {}, {})
        call("openWorkspaceScreen", screen)
        call("requestWorkspaces", org.json.JSONObject().put("action", "list"))
        assertEquals(pending, field("workspaceRequest").get(activity))
        call("closeWorkspaces")
        assertEquals(pending, field("workspaceRequest").get(activity))
        call("openWorkspaceScreen", WorkspaceScreen(activity, {}, {}, {}))
        call("requestWorkspaces", org.json.JSONObject().put("action", "list"))
        assertEquals(pending, field("workspaceRequest").get(activity))
        assertEquals("summary", field("workspaceAction").get(activity))
        call("receiveWorkspaces", """{"id":"$pending","error":"Unavailable"}""")
        assertEquals("list", field("workspaceAction").get(activity))
        assertNotEquals(pending, field("workspaceRequest").get(activity))
        assertEquals("Connected", notice.text.toString())
        assertFalse(field("workspaceSelecting").getBoolean(activity))
        controller.pause().stop().destroy()
    }
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
    @Test fun emptyServerInventoryExistsWithoutNetworkOrCredentials() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        val views = children(activity.window.decorView)
        val cards = views.filterIsInstance<com.google.android.material.card.MaterialCardView>()
        assertTrue(cards.isEmpty())
        assertFalse(views.any { it.javaClass.name.contains("WebView") })
        assertFalse(views.any { it is android.widget.HorizontalScrollView })
        assertFalse(views.filterIsInstance<android.widget.TextView>().any { it.text.contains("Tap to connect") })
        assertTrue(views.any { it is com.google.android.material.appbar.MaterialToolbar })
        controller.pause().stop().destroy()
    }
}
