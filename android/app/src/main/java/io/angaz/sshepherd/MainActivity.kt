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
        toolbar(content, accessories)
        view.onInput = ::enqueueInput
        view.onGeometry = { _, _ -> resizePending = true; flushInput() }
        view.onFailure = { message -> disconnect(); setNotice(message, true) }
        view.onMessage = { message -> setNotice(message, true) }
        root.addView(content, FrameLayout.LayoutParams(-1, -1))
        view.requestFocus()
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
        contentDialog = AlertDialog.Builder(this).setTitle(if (content is PasteContent.Image) "Paste image through Herdr?" else "Paste file/text contents?")
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
        imageTransfer?.let { transfer ->
            transfer.pump { Native.send(session, it) }
            if (transfer.done) {
                imageTransfer = null
                view.acceptingInput = true
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
                } else {
                    phase = event.getString("phase")
                    terminal?.acceptingInput = phase == "connected" && imageTransfer == null
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
        cancelContentRead()
        imageTransfer = null; imageBytes = 0; pickerSession = 0
        contentDialog?.dismiss(); contentDialog = null
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
        destroyed = true; contentReader.shutdownNow(); handler.removeCallbacksAndMessages(null); disconnect(); terminal?.close(); terminal = null
        super.onDestroy()
    }
}
