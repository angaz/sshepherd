package io.angaz.sshepherd

import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AlertDialog
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import com.google.android.material.checkbox.MaterialCheckBox
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.textfield.TextInputLayout
import com.google.android.material.textfield.TextInputEditText
import android.content.ClipboardManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.util.Base64
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject
import java.util.ArrayDeque

/** Entire UI is Android Views. No browser, JavaScript runtime or web assets. */
class MainActivity : AppCompatActivity() {
    private lateinit var root: FrameLayout
    private lateinit var tokens: TokenStore
    private lateinit var hostStore: HostStore
    private val handler = Handler(Looper.getMainLooper())
    private var terminal: TerminalView? = null
    private var notice: TextView? = null
    private var noticeMessage = ""
    private var noticeError = false
    private var agentSummary: AgentSummary? = null
    private var controls: TerminalControls? = null
    private var terminalContent: View? = null
    private var workspaceScreen: WorkspaceScreen? = null
    private var scratchpadScreen: ScratchpadScreen? = null
    private var scratchpadDiscardDialog: AlertDialog? = null
    private var workspaceRequest: String? = null
    private var workspaceAction: String? = null
    private var workspaceSelecting = false
    private var workspaceTimeout: Runnable? = null
    private var session = 0L
    private var activeHost: HostEntry? = null
    private var phase = "idle"
    private var destroyed = false
    private var away = false
    private var hosts = emptyList<HostEntry>()
    private val failures = mutableSetOf<String>()
    private val outbound = ArrayDeque<ByteArray>()
    private var queuedBytes = 0
    private var resizePending = false
    private var imageTransfer: ImageTransfer? = null
    private var imageBytes = 0
    private var readingContent = false
    private var contentDialog: AlertDialog? = null
    private var pickerSession = 0L
    private var contentReadJob: ContentReadJob? = null
    private var contentTimeout: Runnable? = null
    // No queued requests/grants. A provider ignoring cancellation cannot block
    // the next request; two stuck providers fail boundedly rather than leak threads.
    private val contentReader = java.util.concurrent.ThreadPoolExecutor(0, 2, 20,
        java.util.concurrent.TimeUnit.SECONDS, java.util.concurrent.SynchronousQueue(),
        java.util.concurrent.ThreadFactory { work -> Thread(work, "clipboard-file-reader").apply { isDaemon = true } })
    private val disconnectInBackground = Runnable {
        if (away && !destroyed) {
            if (scratchpadScreen != null) disconnect() else showServers()
        }
    }
    private val refreshAgentSummary = object : Runnable {
        override fun run() {
            if (destroyed || terminal == null || activeHost == null) return
            if (!away && phase == "connected" && workspaceScreen == null && scratchpadScreen == null && workspaceRequest == null &&
                !workspaceSelecting && imageTransfer == null && !readingContent && contentDialog == null) {
                requestWorkspaces(JSONObject().put("action", "summary"))
            }
            handler.postDelayed(this, 2000)
        }
    }
    private val backgroundColor = 0xff10141c.toInt()
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (android.os.Build.VERSION.SDK_INT >= 30) window.setDecorFitsSystemWindows(false)
        tokens = TokenStore(this)
        hostStore = HostStore(this)
        root = FrameLayout(this).apply { setBackgroundColor(backgroundColor) }
        setContentView(root)
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            root.setOnApplyWindowInsetsListener { view, insets ->
                val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars() or android.view.WindowInsets.Type.displayCutout())
                val ime = insets.getInsets(android.view.WindowInsets.Type.ime())
                view.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
                insets
            }
        }
        onBackPressedDispatcher.addCallback(this, object : androidx.activity.OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { navigateBack() }
        })
        showServers()
    }
    private fun column() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    private fun label(value: String, size: Float = 16f) = TextView(this).apply {
        text = value; textSize = size; setTextColor(0xffe6edf3.toInt()); setPadding(dp(16), dp(10), dp(16), dp(10))
    }
    private fun button(value: String, action: () -> Unit) = MaterialButton(this).apply {
        text = value; isAllCaps = false; minHeight = dp(48)
        isFocusable = true; isFocusableInTouchMode = false
        setOnClickListener { action() }
    }
    private fun appBar(titleText: String, subtitleText: String) = MaterialToolbar(this).apply {
        title = titleText; subtitle = subtitleText
        setBackgroundColor(backgroundColor)
        setTitleTextColor(0xffe6edf3.toInt()); setSubtitleTextColor(0xffb5c5cd.toInt())
    }
    private fun navigateBack() {
        if (scratchpadScreen != null) backFromScratchpad()
        else if (workspaceScreen != null) backFromWorkspaces()
        else if (controls?.expanded == true) controls?.setExpanded(false)
        else if (activeHost != null) showServers() else finish()
    }
    private fun showServers() {
        disconnect()
        closeScratchpad()
        activeHost = null
        terminal?.let { (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(it.windowToken, 0); it.close() }
        terminal = null
        terminalContent = null
        controls = null
        root.removeAllViews()
        hosts = hostStore.read()
        val content = column()
        content.addView(appBar("SSHepherd", "Your terminals").apply {
            menu.add(0, 1, 0, "Add host").setIcon(R.drawable.ic_add).setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_ALWAYS)
            menu.add(0, 2, 1, "Connection settings").setIcon(R.drawable.ic_settings).setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_ALWAYS)
            setOnMenuItemClickListener { if (it.itemId == 1) showHostEditor() else showSettings(); true }
        }, LinearLayout.LayoutParams(-1, dp(64)))
        content.addView(label("Servers", 22f))
        content.addView(label("Choose a server to connect.", 14f))
        val inventory = column().apply { setPadding(dp(12), dp(4), dp(12), dp(8)) }
        for (host in hosts) {
            val failed = host.id in failures
            val details = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = android.view.Gravity.CENTER_VERTICAL
                minimumHeight = dp(64); setPadding(dp(12), dp(4), dp(4), dp(4))
            }
            details.addView(label(host.name, 16f).apply {
                setPadding(0, 0, dp(8), 0); setTypeface(typeface, android.graphics.Typeface.BOLD)
                maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END
                if (failed) setTextColor(0xffff9d93.toInt())
            }, LinearLayout.LayoutParams(0, -2, 1f))
            details.addView(label(host.address, 12f).apply {
                setPadding(0, 0, dp(8), 0); setTextColor(0xffb5c5cd.toInt())
                gravity = android.view.Gravity.END; maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END
            }, LinearLayout.LayoutParams(0, -2, 1.25f))
            details.addView(button("") { showHostEditor(host) }.apply {
                setIconResource(R.drawable.ic_edit); iconSize = dp(20); iconPadding = 0
                iconGravity = MaterialButton.ICON_GRAVITY_TEXT_START
                contentDescription = "Edit ${host.name}"; tooltipText = contentDescription
            }, LinearLayout.LayoutParams(dp(48), dp(48)))
            val card = MaterialCardView(this).apply {
                radius = dp(14).toFloat(); cardElevation = 0f
                setCardBackgroundColor(0xff1b252e.toInt())
                strokeWidth = dp(1); setStrokeColor(0xff30414a.toInt())
                isClickable = true; isFocusable = true
                contentDescription = "${host.name}. ${host.address}${if (failed) ". Last connection failed" else ""}"
                setOnClickListener { connectTo(host) }
                addView(details)
            }
            inventory.addView(card, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(8) })
        }
        content.addView(ScrollView(this).apply { addView(inventory) }, LinearLayout.LayoutParams(-1, 0, 1f))
        if (hosts.isEmpty()) inventory.addView(label("No hosts yet. Use + to add one.", 15f))
        notice = label("Hosts stay listed even when offline. Use the pencil to edit.", 13f)
        content.addView(notice)
        root.addView(content, FrameLayout.LayoutParams(-1, -1))
    }
    private fun showHostEditor(existing: HostEntry? = null) {
        val layout = column().apply { setPadding(dp(20), dp(8), dp(20), dp(8)) }
        fun field(title: String, value: String, id: Int): Pair<TextInputLayout, TextInputEditText> {
            val box = TextInputLayout(this).apply { hint = title; boxBackgroundMode = TextInputLayout.BOX_BACKGROUND_OUTLINE }
            val input = TextInputEditText(box.context).apply {
                this.id = id; setSingleLine(true); setText(value)
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            }
            box.addView(input)
            layout.addView(box, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(12) })
            return box to input
        }
        val (nameBox, name) = field("Name", existing?.name.orEmpty(), R.id.host_name)
        val (addressBox, address) = field("Hostname or IP address", existing?.address.orEmpty(), R.id.host_address)
        addressBox.helperText = "Private addresses only · UDP 7443"
        layout.addView(label("These hosts receive your shared Eternal token. Use only trusted private addresses; TLS identity is not verified.", 13f))
        val builder = MaterialAlertDialogBuilder(this).setTitle(if (existing == null) "Add host" else "Edit host")
            .setView(ScrollView(this).apply { addView(layout) })
            .setNegativeButton("Cancel", null).setPositiveButton("Save", null)
        if (existing != null) builder.setNeutralButton("Delete") { _, _ ->
            MaterialAlertDialogBuilder(this).setTitle("Delete ${existing.name}?")
                .setMessage("This removes it from this phone only. The remote machine is unchanged.")
                .setNegativeButton("Cancel", null).setPositiveButton("Delete") { _, _ ->
                    try {
                        hostStore.save(hosts.filterNot { it.id == existing.id })
                        failures.remove(existing.id); showServers()
                    } catch (_: Exception) { setNotice("Could not save hosts", true) }
                }.show()
        }
        val dialog = builder.create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                nameBox.error = null; addressBox.error = null
                try {
                    val entry = HostStore.entry(name.text.toString(), address.text.toString(), existing?.id ?: java.util.UUID.randomUUID().toString())
                    val updated = if (existing == null) hosts + entry else hosts.map { if (it.id == existing.id) entry else it }
                    hostStore.save(updated)
                    failures.remove(entry.id)
                    dialog.dismiss(); showServers()
                } catch (error: Exception) {
                    addressBox.error = error.message ?: "Enter a valid name and hostname/IP"
                }
            }
        }
        dialog.show()
    }
    private fun showTerminal(host: HostEntry) {
        root.removeAllViews()
        val content = column()
        terminalContent = content
        val view = TerminalView(this)
        terminal = view
        activeHost = host
        content.addView(appBar(host.name, host.address).apply {
            setNavigationIcon(R.drawable.ic_back)
            navigationContentDescription = "Servers"
            setNavigationOnClickListener { showServers() }
            menu.add(0, 1, 0, "Previous tab").setIcon(R.drawable.ic_previous).setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_ALWAYS)
            menu.add(0, 2, 1, "Next tab").setIcon(R.drawable.ic_next).setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_ALWAYS)
            menu.add(0, 3, 2, "Workspaces").setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_ALWAYS or android.view.MenuItem.SHOW_AS_ACTION_WITH_TEXT)
            menu.add(0, 4, 3, "Zoom pane")
            menu.add(0, 5, 4, "Scrollback scratchpad")
            setOnMenuItemClickListener {
                when (it.itemId) { 1 -> view.herdrAction('p'); 2 -> view.herdrAction('n'); 3 -> showWorkspaces(view); 4 -> view.herdrAction('z'); 5 -> showScratchpad(view) }
                true
            }
        }, LinearLayout.LayoutParams(-1, dp(56)))
        notice = label("Connecting to ${host.name}…", 12f).apply {
            setPadding(dp(16), dp(5), dp(16), dp(5))
            setBackgroundColor(0xff182029.toInt())
        }
        content.addView(notice)
        content.addView(view, LinearLayout.LayoutParams(-1, 0, 1f))
        val ctrl = button("Ctrl") {}.apply { isCheckable = true; contentDescription = "Control modifier off" }
        ctrl.setOnClickListener {
            view.ctrlLatched = ctrl.isChecked
            ctrl.contentDescription = if (ctrl.isChecked) "Control modifier on" else "Control modifier off"
            ctrl.tooltipText = ctrl.contentDescription
        }
        view.onCtrlConsumed = {
            ctrl.isChecked = false; ctrl.contentDescription = "Control modifier off"
            ctrl.tooltipText = ctrl.contentDescription
        }
        fun key(name: String, code: Int, description: String = name) = button(name) { view.accessory(code) }.apply { contentDescription = description }
        val primary = listOf(
            listOf(key("Esc", KeyEvent.KEYCODE_ESCAPE, "Escape"), key("Tab", KeyEvent.KEYCODE_TAB),
                key("Home", KeyEvent.KEYCODE_MOVE_HOME), key("↑", KeyEvent.KEYCODE_DPAD_UP, "Up arrow"),
                key("End", KeyEvent.KEYCODE_MOVE_END), key("PgUp", KeyEvent.KEYCODE_PAGE_UP, "Page up")),
            listOf(ctrl, button("Ctrl+C") { view.accessory(KeyEvent.KEYCODE_C, 2) },
                key("←", KeyEvent.KEYCODE_DPAD_LEFT, "Left arrow"), key("↓", KeyEvent.KEYCODE_DPAD_DOWN, "Down arrow"),
                key("→", KeyEvent.KEYCODE_DPAD_RIGHT, "Right arrow"), key("PgDn", KeyEvent.KEYCODE_PAGE_DOWN, "Page down"))
        )
        val accessories = mutableListOf(key("Enter", KeyEvent.KEYCODE_ENTER), key("⌫", KeyEvent.KEYCODE_DEL, "Backspace"),
            key("Del", KeyEvent.KEYCODE_FORWARD_DEL, "Forward delete"))
        accessories.add(button("Ctrl+D") { view.accessory(KeyEvent.KEYCODE_D, 2) })
        accessories.add(button("Prefix") { view.accessory(KeyEvent.KEYCODE_A, 2) })
        accessories.add(button("Paste") {
            val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
            val clip = clipboard.primaryClip
            if (clip == null || clip.itemCount != 1) { setNotice("Copy one text item or file first.", true); return@button }
            val item = clip.getItemAt(0)
            val uri = item.uri
            if (uri != null) readContent(uri, view)
            else item.text?.toString()?.takeIf { it.isNotEmpty() }?.let { confirmContent(PasteContent.Text(it), session, view) }
        })
        accessories.add(button("Attach") {
            if (phase != "connected" || imageTransfer != null || readingContent || contentDialog != null) return@button
            pickerSession = session
            startActivityForResult(android.content.Intent(android.content.Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(android.content.Intent.CATEGORY_OPENABLE); type = "*/*"
            }, 727)
        })
        view.onContent = { info, flags ->
            var granted = false
            try {
                if (flags and android.view.inputmethod.InputConnection.INPUT_CONTENT_GRANT_READ_URI_PERMISSION != 0) {
                    info.requestPermission(); granted = true
                }
                val release = { if (granted) info.releasePermission() }
                if (readContent(info.contentUri, view, release)) true
                else { release(); false }
            } catch (_: Exception) {
                if (granted) runCatching { info.releasePermission() }
                setNotice("Cannot read the keyboard's image.", true); false
            }
        }
        controls = TerminalControls(this, primary, accessories, view::showKeyboard)
        content.addView(controls, LinearLayout.LayoutParams(-1, -2))
        view.onInput = ::enqueueInput
        view.onGeometry = { _, _ -> resizePending = true; flushInput() }
        view.onFailure = { message -> disconnect(); setNotice(message, true) }
        view.onMessage = { message -> setNotice(message, true) }
        view.onClipboard = { bytes ->
            // Drain but discard background/stale-session requests. Remote output
            // must not replace the phone clipboard when this app isn't active.
            if (!away && !destroyed && hasWindowFocus() && view.isShown && view === terminal && phase == "connected") {
                if (!RemoteClipboard.write(this, bytes)) setNotice("Could not copy remote text to the phone clipboard.", true)
            }
        }
        root.addView(content, FrameLayout.LayoutParams(-1, -1))
        view.requestFocus()
    }
    private fun showScratchpad(view: TerminalView) {
        if (scratchpadScreen != null || workspaceScreen != null || workspaceSelecting || phase != "connected" ||
            imageTransfer != null || readingContent || contentDialog != null) return
        if (!view.prepareContent()) return
        openScratchpadScreen(ScratchpadScreen(this, { requestWorkspaces(JSONObject().put("action", "scrollback")) }, ::backFromScratchpad))
        requestWorkspaces(JSONObject().put("action", "scrollback"))
    }
    private fun openScratchpadScreen(screen: ScratchpadScreen) {
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(root.windowToken, 0)
        terminal?.clearFocus(); terminal?.acceptingInput = false
        terminalContent?.visibility = View.INVISIBLE
        scratchpadScreen = screen
        root.addView(screen, FrameLayout.LayoutParams(-1, -1))
        screen.requestFocus()
    }
    private fun backFromScratchpad() {
        if (scratchpadScreen?.hasEdits != true) { closeScratchpad(); return }
        if (scratchpadDiscardDialog != null) return
        scratchpadDiscardDialog = MaterialAlertDialogBuilder(this).setTitle("Discard scratchpad edits?")
            .setMessage("Edits are local only. Copy anything you want to keep before closing.")
            .setNegativeButton("Keep editing", null).setPositiveButton("Discard") { _, _ -> closeScratchpad() }
            .create().also { dialog ->
                dialog.setOnDismissListener { if (scratchpadDiscardDialog === dialog) scratchpadDiscardDialog = null }
                dialog.show()
            }
    }
    private fun closeScratchpad() {
        scratchpadDiscardDialog?.dismiss(); scratchpadDiscardDialog = null
        scratchpadScreen?.let {
            (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(it.windowToken, 0)
            root.removeView(it)
        }
        scratchpadScreen = null
        terminalContent?.visibility = View.VISIBLE
        terminal?.acceptingInput = phase == "connected" && imageTransfer == null && !workspaceSelecting && workspaceScreen == null
        terminal?.requestFocus()
    }
    private fun clearWorkspaceRequest() {
        workspaceTimeout?.let { handler.removeCallbacks(it) }
        workspaceTimeout = null; workspaceRequest = null; workspaceAction = null
    }
    private fun showWorkspaces(view: TerminalView) {
        // Commit pre-edit before hiding the IME; opening this native list never
        // sends Ctrl+A/W or opens the terminal-rendered sidebar.
        if (workspaceScreen != null || scratchpadScreen != null) return
        view.prepareContent()
        val id = session
        openWorkspaceScreen(WorkspaceScreen(this, refresh = ::refreshWorkspaces, select = { row ->
            // Pre-edit was committed before opening, and terminal input stays
            // disabled while browsing this screen.
            if (session != id || view !== terminal || imageTransfer != null || phase != "connected") {
                workspaceScreen?.error("Cannot switch while disconnected or sending content.")
            } else {
                requestWorkspaces(JSONObject().put("action", if (row.isAgent) "pane" else "workspace")
                    .put(if (row.isAgent) "pane_id" else "workspace_id", row.id))
            }
        }, back = ::backFromWorkspaces, newWorkspace = {
            if (workspaceRequest == null && !workspaceSelecting) {
                workspaceScreen?.projectMode(true)
                refreshWorkspaces()
            }
        }, create = { project ->
            if (session == id && view === terminal && imageTransfer == null && phase == "connected") {
                (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(root.windowToken, 0)
                requestWorkspaces(JSONObject().put("action", "create").put("project", project))
            }
        }))
        if (workspaceSelecting) workspaceScreen?.loading("Waiting for the switch to be confirmed…")
        else {
            workspaceScreen?.loading("Loading workspaces…")
            requestWorkspaces(JSONObject().put("action", "list"))
        }
    }
    private fun refreshWorkspaces() {
        workspaceScreen?.let { requestWorkspaces(JSONObject().put("action", it.browseAction)) }
    }
    private fun backFromWorkspaces() {
        if (workspaceScreen?.isProjectPicker == true && !workspaceSelecting) {
            (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(root.windowToken, 0)
            workspaceScreen?.projectMode(false)
            workspaceScreen?.loading("Loading workspaces…")
            refreshWorkspaces()
        } else closeWorkspaces()
    }
    private fun openWorkspaceScreen(screen: WorkspaceScreen) {
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(root.windowToken, 0)
        terminal?.clearFocus(); terminal?.acceptingInput = false
        // Keep the connected terminal mounted with stable geometry, but remove
        // it and its shortcut bar from touch/focus/accessibility navigation.
        terminalContent?.visibility = View.INVISIBLE
        workspaceScreen = screen
        root.addView(screen, FrameLayout.LayoutParams(-1, -1))
        screen.requestFocus()
    }
    private fun closeWorkspaces() {
        workspaceScreen?.let { root.removeView(it) }
        workspaceScreen = null
        terminalContent?.visibility = if (scratchpadScreen == null) View.VISIBLE else View.INVISIBLE
        // Navigating back cannot cancel a submitted focus RPC. Retain its ID
        // and input guard until confirmation, just as while browsing.
        if (!workspaceSelecting) {
            // Back cannot cancel the bridge's read-only worker either. Keep
            // tracking it so reopening waits for its result instead of racing.
            terminal?.acceptingInput = phase == "connected" && imageTransfer == null && scratchpadScreen == null
            if (scratchpadScreen == null) terminal?.requestFocus()
            (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(root.windowToken, 0)
        }
    }
    private fun requestWorkspaces(request: JSONObject) {
        val action = request.getString("action")
        val summary = action == "summary"
        val screen = workspaceScreen
        val scratchpad = scratchpadScreen
        val scrollback = action == "scrollback"
        if (screen == null && !summary && !(scrollback && scratchpad != null)) return
        if (workspaceRequest != null) return
        if (phase != "connected") {
            if (!summary) screen?.error("Not connected. Reconnect and open the list again.")
            if (scrollback) scratchpad?.error("Not connected. Reconnect and open the scratchpad again.")
            return
        }
        val id = java.util.UUID.randomUUID().toString()
        request.put("id", id)
        workspaceRequest = id; workspaceAction = action
        workspaceSelecting = action in listOf("workspace", "pane", "create")
        if (workspaceSelecting) terminal?.acceptingInput = false
        if (!summary) screen?.loading(when (action) {
            "projects" -> "Loading projects…"
            "create" -> "Creating workspace…"
            "workspace", "pane" -> "Switching…"
            else -> "Loading workspaces…"
        })
        if (scrollback) scratchpad?.loading()
        if (!enqueueFrame(PtyFrames.directory(request))) {
            if (summary) finishAgentSummary(null)
            else {
                clearWorkspaceRequest(); finishWorkspaceSelection()
                screen?.error("Input queue full. Try refreshing.")
                if (scrollback) scratchpad?.error("Input queue full. Tap Retry.")
            }
            return
        }
        workspaceTimeout = Runnable {
            if (workspaceRequest == id) {
                if (summary) finishAgentSummary(null)
                else if (workspaceSelecting) {
                    // A network timeout does not prove a focus mutation failed.
                    // Never resume typing into an unconfirmed target.
                    workspaceTimeout = null
                    workspaceScreen?.loading("Switch not confirmed. Input remains paused; reconnect if needed.")
                    setNotice("Switch not confirmed. Input paused; return to Servers to reconnect.", true)
                } else {
                    clearWorkspaceRequest(); workspaceScreen?.error("Workspace request timed out. Refresh to retry.")
                    scratchpadScreen?.error("Scrollback request timed out. Tap Retry.")
                }
            }
        }.also { handler.postDelayed(it, 8000) }
    }
    private fun finishWorkspaceSelection() {
        workspaceSelecting = false
        terminal?.acceptingInput = phase == "connected" && imageTransfer == null && workspaceScreen == null && scratchpadScreen == null
        if (workspaceScreen == null && scratchpadScreen == null) terminal?.requestFocus()
    }
    private fun finishAgentSummary(summary: AgentSummary?) {
        clearWorkspaceRequest()
        agentSummary = summary; renderNotice()
        // An interactive list waits behind a pending read-only summary, never
        // races it on the bridge's single bounded API worker.
        if (scratchpadScreen != null) requestWorkspaces(JSONObject().put("action", "scrollback")) else refreshWorkspaces()
    }
    private fun receiveWorkspaces(data: String) {
        try {
            val response = JSONObject(data)
            if (response.optString("id") != workspaceRequest) return
            val error = response.optString("error")
            if (workspaceAction == "summary") {
                finishAgentSummary(if (error.isEmpty()) AgentSummary.decode(response.getJSONObject("summary")) else null)
                return
            }
            if (workspaceSelecting && response.optBoolean("uncertain")) {
                workspaceTimeout?.let { handler.removeCallbacks(it) }; workspaceTimeout = null
                workspaceScreen?.loading("Switch may have been applied. Input paused; reconnect to continue.")
                setNotice("Switch may have been applied. Input paused; return to Servers to reconnect.", true)
                return
            }
            if (workspaceSelecting && error.isEmpty()) require(response.optBoolean("selected"))
            val wasSelecting = workspaceSelecting
            val action = workspaceAction
            clearWorkspaceRequest()
            finishWorkspaceSelection()
            if (wasSelecting && phase == "connected") setNotice(if (error.isEmpty()) "Connected" else error.take(512), error.isNotEmpty())
            when {
                !wasSelecting && scratchpadScreen != null && action != "scrollback" -> requestWorkspaces(JSONObject().put("action", "scrollback"))
                action == "scrollback" && scratchpadScreen != null -> {
                    if (error.isNotEmpty()) scratchpadScreen?.error("Scrollback unavailable. Tap Retry.")
                    else scratchpadScreen?.display(ScrollbackSnapshot.decode(response.getJSONObject("scrollback")))
                }
                !wasSelecting && workspaceScreen != null && action != workspaceScreen?.browseAction -> refreshWorkspaces()
                error.isNotEmpty() -> workspaceScreen?.error(error.take(512))
                wasSelecting -> closeWorkspaces()
                action == "projects" -> workspaceScreen?.displayProjects(ProjectDirectory.decode(response))
                else -> workspaceScreen?.display(WorkspaceDirectory.rows(response))
            }
        } catch (_: Exception) {
            if (workspaceAction == "summary") finishAgentSummary(null)
            else if (workspaceSelecting) workspaceScreen?.loading("Invalid switch confirmation. Input paused; reconnect to continue.")
            else {
                clearWorkspaceRequest(); workspaceScreen?.error("Invalid workspace list. Refresh to retry.")
                scratchpadScreen?.error("Invalid scrollback snapshot. Tap Retry.")
            }
        }
    }
    @Deprecated("Legacy activity result API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 727 && resultCode == RESULT_OK && pickerSession == session) {
            val view = terminal ?: return
            data?.data?.let { readContent(it, view) }
        }
        if (requestCode == 727) pickerSession = 0
    }
    private fun readContent(uri: android.net.Uri, view: TerminalView, release: () -> Unit = {}): Boolean {
        if (uri.scheme != "content" || destroyed || phase != "connected" || view !== terminal || readingContent || imageTransfer != null || contentDialog != null) return false
        val id = session
        readingContent = true
        setNotice("Reading file…")
        val cancellation = android.os.CancellationSignal()
        lateinit var job: ContentReadJob
        job = ContentReadJob(open = {
            val descriptor = contentResolver.openAssetFileDescriptor(uri, "r", cancellation)
                ?: throw IllegalArgumentException("Cannot open file")
            try { descriptor.createInputStream() } catch (error: Exception) { descriptor.close(); throw error }
        }, cancelProvider = { cancellation.cancel() }, release = release) { result ->
            handler.post {
                if (!destroyed && session == id && view === terminal && contentReadJob === job) {
                    contentTimeout?.let { handler.removeCallbacks(it) }; contentTimeout = null
                    contentReadJob = null; readingContent = false
                    result.onSuccess { confirmContent(it, id, view) }
                        .onFailure { setNotice("Cannot paste file. Use PNG/JPEG/GIF/WebP/BMP (≤16 MiB) or UTF-8 text (≤60 KB).", true) }
                }
            }
        }
        contentReadJob = job
        contentTimeout = Runnable {
            if (contentReadJob === job) {
                cancelContentRead()
                setNotice("File provider timed out. Try selecting the file again.", true)
            }
        }.also { handler.postDelayed(it, 15000) }
        try { contentReader.execute(job) } catch (_: java.util.concurrent.RejectedExecutionException) {
            cancelContentRead()
            setNotice("File provider is busy. Retry or restart the app.", true)
        }
        // Ownership of permission release has transferred, including rejection.
        return true
    }
    private fun cancelContentRead() {
        contentTimeout?.let { handler.removeCallbacks(it) }; contentTimeout = null
        val job = contentReadJob; contentReadJob = null
        readingContent = false
        job?.cancel()
    }
    private fun confirmContent(content: PasteContent, id: Long, view: TerminalView) {
        if (id == 0L || session != id || terminal !== view || phase != "connected" || imageTransfer != null || contentDialog != null) return
        val message = when (content) {
            is PasteContent.Text -> "${content.value.length} characters. Pasted text may execute commands."
            is PasteContent.Image -> "${content.bytes.size / 1024} KB ${content.extension.uppercase()}. Herdr will save the image remotely and paste its path into the current terminal."
        }
        contentDialog = MaterialAlertDialogBuilder(this).setTitle(if (content is PasteContent.Image) "Paste image through Herdr?" else "Paste file/text contents?")
            .setMessage(message).setNegativeButton("Cancel", null).setPositiveButton("Paste") { _, _ ->
                if (session != id || terminal !== view || phase != "connected" || imageTransfer != null) return@setPositiveButton
                when (content) {
                    is PasteContent.Text -> view.paste(content.value)
                    is PasteContent.Image -> {
                        if (imageBytes + content.bytes.size > 64 * 1024 * 1024) {
                            setNotice("Image session quota reached (64 MiB). Reconnect to upload more.", true)
                        } else if (view.prepareContent()) {
                            imageBytes += content.bytes.size
                            imageTransfer = ImageTransfer(content)
                            view.acceptingInput = false
                            setNotice("Sending image to Herdr…")
                            flushInput()
                        }
                    }
                }
            }.create().also { dialog ->
                dialog.setOnDismissListener { if (contentDialog === dialog) contentDialog = null }
                dialog.show()
            }
    }
    private fun connectTo(host: HostEntry) {
        if (destroyed || host !in hosts) return
        disconnect()
        val token = try { tokens.read() } catch (_: Exception) { tokens.clear(); null }
        if (token.isNullOrBlank() || !tokens.consented()) { showSettings(); return }
        try {
            showTerminal(host)
            phase = "connecting"
            val id = Native.open(host.address, token)
            check(id != 0L) { "Could not start transport" }
            session = id
            poll(id)
        } catch (error: Exception) {
            failures.add(host.id); disconnect(); setNotice(error.message ?: "Connection failed", true)
        } catch (_: LinkageError) {
            disconnect(); setNotice("Native library unavailable for this device", true)
        }
    }
    private fun setNotice(message: String, error: Boolean = false) {
        noticeMessage = message; noticeError = error
        renderNotice()
    }
    private fun renderNotice() {
        val summary = if (phase == "connected" && activeHost != null && !noticeError) agentSummary?.text else null
        notice?.text = if (summary == null) noticeMessage else "$noticeMessage · $summary"
        notice?.setTextColor(if (noticeError) 0xffff9d93.toInt() else 0xffb5c5d8.toInt())
    }
    private fun enqueueInput(bytes: ByteArray): Boolean {
        if (phase != "connected" || bytes.isEmpty()) return false
        if (bytes.size > 65536) return false
        return enqueueFrame(PtyFrames.input(bytes))
    }
    private fun enqueueFrame(frame: ByteArray): Boolean {
        if (phase != "connected") return false
        if (queuedBytes + frame.size > 128 * 1024) {
            setNotice("Input queue full; input was not sent.", true); return false
        }
        outbound.addLast(frame); queuedBytes += frame.size
        flushInput()
        return true
    }
    private fun flushInput() {
        val view = terminal ?: return
        if (phase != "connected" || session == 0L) return
        if (resizePending) {
            if (!Native.send(session, PtyFrames.resize(view.cols, view.rows))) return
            resizePending = false
        }
        while (outbound.isNotEmpty()) {
            val frame = outbound.first
            if (!Native.send(session, frame)) return
            outbound.removeFirst(); queuedBytes -= frame.size
        }
        imageTransfer?.let { transfer ->
            transfer.pump { Native.send(session, it) }
            if (transfer.done) {
                imageTransfer = null
                view.acceptingInput = workspaceScreen == null && scratchpadScreen == null && !workspaceSelecting
                setNotice("Image queued for Herdr image paste.")
            }
        }
    }
    private fun poll(id: Long) {
        if (destroyed || id != session) return
        try {
            // Bounded work per UI frame; Ghostty snapshots are coalesced in onDraw.
            val started = SystemClock.uptimeMillis()
            var count = 0
            while (count++ < 8 && SystemClock.uptimeMillis() - started < 6) {
                val raw = Native.poll(id)
                if (raw.isEmpty()) break
                val event = JSONObject(raw)
                if (event.getString("kind") == "output") {
                    terminal?.feed(Base64.decode(event.getString("data"), Base64.NO_WRAP))
                } else if (event.getString("kind") == "directory") {
                    receiveWorkspaces(event.getString("data"))
                } else {
                    phase = event.getString("phase")
                    terminal?.acceptingInput = phase == "connected" && imageTransfer == null && !workspaceSelecting && workspaceScreen == null && scratchpadScreen == null
                    if (phase != "connected") {
                        agentSummary = null
                        scratchpadScreen?.error("Connection interrupted. Retry after reconnecting.")
                        if (workspaceSelecting) workspaceScreen?.loading("Connection interrupted; waiting for switch confirmation…")
                        else { clearWorkspaceRequest(); workspaceScreen?.error("Connection interrupted. Refresh after reconnecting.") }
                    }
                    setNotice(if (phase == "connected" && workspaceSelecting) "Connected; waiting for workspace switch confirmation. Input paused."
                        else event.getString("message"), phase == "error")
                    if (phase == "connected") {
                        activeHost?.let { failures.remove(it.id) }; resizePending = true
                        handler.removeCallbacks(refreshAgentSummary); handler.post(refreshAgentSummary)
                    }
                    if (phase == "error") activeHost?.let { failures.add(it.id) }
                }
            }
            flushInput() // retries the latest resize even if no new geometry event arrives
        } catch (error: Exception) {
            disconnect(); setNotice(error.message ?: "Terminal failed", true); return
        }
        if (phase != "error" && phase != "closed") handler.postDelayed({ poll(id) }, 16)
    }
    private fun disconnect() {
        val old = session; session = 0; phase = "idle"
        handler.removeCallbacks(refreshAgentSummary); agentSummary = null
        clearWorkspaceRequest(); workspaceSelecting = false
        closeWorkspaces()
        // The snapshot belongs to the phone, not the transport. Keep local
        // edits alive across automatic detach/failure until explicit Back.
        scratchpadScreen?.disconnected()
        terminal?.acceptingInput = false
        outbound.clear(); queuedBytes = 0; resizePending = false
        cancelContentRead()
        imageTransfer = null; imageBytes = 0; pickerSession = 0
        contentDialog?.dismiss(); contentDialog = null
        if (old != 0L) Native.close(old)
    }
    private fun showSettings() {
        if (destroyed) return
        val layout = column().apply { setPadding(dp(20), dp(8), dp(20), 0) }
        layout.addView(label("Paste the shared token from your trusted server. Android Keystore encrypts it.\n\nQUIC uses self-signed certificates without CA identity verification. Authenticate server identity independently using trusted endpoints and DNS.", 14f))
        val tokenField = TextInputLayout(this).apply {
            hint = "Token (blank keeps existing)"
            boxBackgroundMode = TextInputLayout.BOX_BACKGROUND_OUTLINE
            endIconMode = TextInputLayout.END_ICON_PASSWORD_TOGGLE
        }
        val token = TextInputEditText(tokenField.context).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setSingleLine(true); importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        tokenField.addView(token)
        layout.addView(tokenField)
        val consent = MaterialCheckBox(this).apply { text = "I trust the configured servers and DNS; TLS identity is not verified"; isChecked = tokens.consented() }
        layout.addView(consent)
        val dialog = MaterialAlertDialogBuilder(this).setTitle("Connection settings").setView(ScrollView(this).apply { addView(layout) })
            .setNegativeButton("Cancel", null).setNeutralButton("Forget token") { _, _ -> disconnect(); tokens.clear(); showServers() }
            .setPositiveButton("Save", null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                try {
                    val value = token.text.toString().trim().ifEmpty { tokens.read().orEmpty() }
                    if (!consent.isChecked || value.isEmpty() || value.toByteArray().size > 8192) {
                        Toast.makeText(this, "Enter a token and confirm server trust", Toast.LENGTH_LONG).show()
                    } else {
                        disconnect(); tokens.save(value); token.text?.clear(); dialog.dismiss(); showServers()
                        Toast.makeText(this, "Saved. Tap a server to connect.", Toast.LENGTH_SHORT).show()
                    }
                } catch (_: Exception) { Toast.makeText(this, "Could not save token in Keystore", Toast.LENGTH_LONG).show() }
            }
        }
        dialog.show()
    }
    override fun onStop() { super.onStop(); away = true; handler.postDelayed(disconnectInBackground, 60_000) }
    override fun onStart() { super.onStart(); away = false; handler.removeCallbacks(disconnectInBackground) }
    override fun onDestroy() {
        destroyed = true; contentReader.shutdownNow(); handler.removeCallbacksAndMessages(null); disconnect(); closeScratchpad(); terminal?.close(); terminal = null
        super.onDestroy()
    }
}
