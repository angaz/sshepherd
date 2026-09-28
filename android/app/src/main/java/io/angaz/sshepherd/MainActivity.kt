package io.angaz.sshepherd

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipboardManager
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.util.Base64
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject
import java.util.ArrayDeque

/** Entire UI is Android Views. No browser, JavaScript runtime or web assets. */
class MainActivity : Activity() {
    private lateinit var root: FrameLayout
    private lateinit var tokens: TokenStore
    private val handler = Handler(Looper.getMainLooper())
    private var terminal: TerminalView? = null
    private var notice: TextView? = null
    private var session = 0L
    private var activeHost: String? = null
    private var phase = "idle"
    private var destroyed = false
    private var away = false
    private val hosts = listOf("host-a", "host-b", "host-c", "host-d", "host-e", "host-f")
    private val failures = mutableSetOf<String>()
    private val outbound = ArrayDeque<ByteArray>()
    private var queuedBytes = 0
    private var resizePending = false
    private val disconnectInBackground = Runnable { if (away && !destroyed) showServers() }
    private val backgroundColor = 0xff10141c.toInt()
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (android.os.Build.VERSION.SDK_INT >= 30) window.setDecorFitsSystemWindows(false)
        tokens = TokenStore(this)
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
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT) {
                if (activeHost != null) showServers() else finish()
            }
        }
        showServers()
    }
    private fun column() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    private fun label(value: String, size: Float = 16f) = TextView(this).apply {
        text = value; textSize = size; setTextColor(0xffe6edf3.toInt()); setPadding(dp(16), dp(10), dp(16), dp(10))
    }
    private fun button(value: String, action: () -> Unit) = Button(this).apply {
        text = value; isAllCaps = false; minHeight = dp(48); setTextColor(0xffe6edf3.toInt())
        setOnClickListener { action() }
    }
    private fun toolbar(parent: LinearLayout, buttons: List<Button>) {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        buttons.forEach { row.addView(it) }
        parent.addView(HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; addView(row) })
    }
    private fun showServers() {
        disconnect()
        activeHost = null
        terminal?.let { (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(it.windowToken, 0); it.close() }
        terminal = null
        root.removeAllViews()
        val content = column()
        content.addView(label("SSHepherd", 24f))
        content.addView(label("Native Ghostty · Herdr Eternal / QUIC", 14f))
        content.addView(button("Connection settings", ::showSettings))
        val inventory = column()
        for (host in hosts) {
            inventory.addView(button("$host\n${host}.example.invalid · ${if (host in failures) "last connection failed — retry" else "tap to connect"}") { connectTo(host) })
        }
        content.addView(ScrollView(this).apply { addView(inventory) }, LinearLayout.LayoutParams(-1, 0, 1f))
        notice = label("All configured machines are listed, including offline servers.", 13f)
        content.addView(notice)
        root.addView(content, FrameLayout.LayoutParams(-1, -1))
    }
    private fun showTerminal(host: String) {
        root.removeAllViews()
        val content = column()
        val view = TerminalView(this)
        terminal = view
        activeHost = host
        toolbar(content, listOf(button("‹ Servers", ::showServers), button(host) {}, button("Keyboard", view::showKeyboard)))
        toolbar(content, listOf(
            button("Prev tab") { view.herdrAction('p') },
            button("Next tab") { view.herdrAction('n') },
            button("Workspaces") { view.herdrAction('w') },
            button("Zoom") { view.herdrAction('z') }
        ))
        notice = label("Connecting to $host…", 13f)
        content.addView(notice)
        content.addView(view, LinearLayout.LayoutParams(-1, 0, 1f))
        val ctrl = button("Ctrl") { view.ctrlLatched = !view.ctrlLatched }
        ctrl.setOnClickListener { view.ctrlLatched = !view.ctrlLatched; ctrl.isSelected = view.ctrlLatched; ctrl.setTextColor(if (view.ctrlLatched) 0xff7ce4c6.toInt() else Color.WHITE) }
        view.onCtrlConsumed = { ctrl.isSelected = false; ctrl.setTextColor(Color.WHITE) }
        val keys = listOf(
            "Esc" to KeyEvent.KEYCODE_ESCAPE, "Tab" to KeyEvent.KEYCODE_TAB,
            "↑" to KeyEvent.KEYCODE_DPAD_UP, "↓" to KeyEvent.KEYCODE_DPAD_DOWN,
            "←" to KeyEvent.KEYCODE_DPAD_LEFT, "→" to KeyEvent.KEYCODE_DPAD_RIGHT,
            "Home" to KeyEvent.KEYCODE_MOVE_HOME, "End" to KeyEvent.KEYCODE_MOVE_END,
            "PgUp" to KeyEvent.KEYCODE_PAGE_UP, "PgDn" to KeyEvent.KEYCODE_PAGE_DOWN
        )
        val accessories = mutableListOf(ctrl, button("Ctrl+C") { view.accessory(KeyEvent.KEYCODE_C, 2) }, button("Enter") { view.accessory(KeyEvent.KEYCODE_ENTER) })
        accessories.addAll(keys.map { (name, code) -> button(name) { view.accessory(code) } })
        accessories.add(button("Ctrl+D") { view.accessory(KeyEvent.KEYCODE_D, 2) })
        accessories.add(button("Prefix") { view.accessory(KeyEvent.KEYCODE_A, 2) })
        accessories.add(button("Paste") {
            val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
            val text = clipboard.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString().orEmpty()
            if (text.isNotEmpty()) AlertDialog.Builder(this).setTitle("Paste into remote terminal?")
                .setMessage("${text.length} characters. Pasted text may execute commands.")
                .setNegativeButton("Cancel", null).setPositiveButton("Paste") { _, _ -> view.paste(text) }.show()
        })
        toolbar(content, accessories)
        view.onInput = ::enqueueInput
        view.onGeometry = { _, _ -> resizePending = true; flushInput() }
        view.onFailure = { message -> disconnect(); setNotice(message, true) }
        view.onMessage = { message -> setNotice(message, true) }
        root.addView(content, FrameLayout.LayoutParams(-1, -1))
        view.requestFocus()
    }
    private fun connectTo(host: String) {
        if (destroyed || host !in hosts) return
        disconnect()
        val token = try { tokens.read() } catch (_: Exception) { tokens.clear(); null }
        if (token.isNullOrBlank() || !tokens.consented()) { showSettings(); return }
        try {
            showTerminal(host)
            phase = "connecting"
            val id = Native.open(host, token)
            check(id != 0L) { "Could not start transport" }
            session = id
            poll(id)
        } catch (error: Exception) {
            failures.add(host); disconnect(); setNotice(error.message ?: "Connection failed", true)
        } catch (_: LinkageError) {
            disconnect(); setNotice("Native library unavailable for this device", true)
        }
    }
    private fun setNotice(message: String, error: Boolean = false) {
        notice?.text = message
        notice?.setTextColor(if (error) 0xffff9d93.toInt() else 0xffb5c5d8.toInt())
    }
    private fun enqueueInput(bytes: ByteArray): Boolean {
        if (phase != "connected" || bytes.isEmpty()) return false
        if (bytes.size > 65536 || queuedBytes + bytes.size + 5 > 128 * 1024) {
            setNotice("Input queue full; input was not sent.", true); return false
        }
        val frame = PtyFrames.input(bytes)
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
                } else {
                    phase = event.getString("phase")
                    terminal?.acceptingInput = phase == "connected"
                    setNotice(event.getString("message"), phase == "error")
                    if (phase == "connected") { activeHost?.let { failures.remove(it) }; resizePending = true }
                    if (phase == "error") activeHost?.let { failures.add(it) }
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
        terminal?.acceptingInput = false
        outbound.clear(); queuedBytes = 0; resizePending = false
        if (old != 0L) Native.close(old)
    }
    private fun showSettings() {
        if (destroyed) return
        val layout = column().apply { setPadding(dp(20), dp(8), dp(20), 0) }
        layout.addView(label("Paste the shared token from your trusted server. Android Keystore encrypts it.\n\nQUIC uses self-signed certificates without CA identity verification. Authenticate server identity independently using trusted endpoints and DNS.", 14f))
        val token = EditText(this).apply {
            hint = "Token (blank keeps existing)"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setSingleLine(true); importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        layout.addView(token)
        val consent = CheckBox(this).apply { text = "I trust the configured servers and DNS; TLS identity is not verified"; isChecked = tokens.consented() }
        layout.addView(consent)
        val dialog = AlertDialog.Builder(this).setTitle("Connection settings").setView(layout)
            .setNegativeButton("Cancel", null).setNeutralButton("Forget token") { _, _ -> disconnect(); tokens.clear(); showServers() }
            .setPositiveButton("Save", null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                try {
                    val value = token.text.toString().trim().ifEmpty { tokens.read().orEmpty() }
                    if (!consent.isChecked || value.isEmpty() || value.toByteArray().size > 8192) {
                        Toast.makeText(this, "Enter a token and confirm server trust", Toast.LENGTH_LONG).show()
                    } else {
                        disconnect(); tokens.save(value); token.text.clear(); dialog.dismiss(); showServers()
                        Toast.makeText(this, "Saved. Tap a server to connect.", Toast.LENGTH_SHORT).show()
                    }
                } catch (_: Exception) { Toast.makeText(this, "Could not save token in Keystore", Toast.LENGTH_LONG).show() }
            }
        }
        dialog.show()
    }
    override fun onStop() { super.onStop(); away = true; handler.postDelayed(disconnectInBackground, 60_000) }
    override fun onStart() { super.onStart(); away = false; handler.removeCallbacks(disconnectInBackground) }
    @Deprecated("Legacy Android back callback")
    override fun onBackPressed() { if (activeHost != null) showServers() else super.onBackPressed() }
    override fun onDestroy() {
        destroyed = true; handler.removeCallbacksAndMessages(null); disconnect(); terminal?.close(); terminal = null
        super.onDestroy()
    }
}
