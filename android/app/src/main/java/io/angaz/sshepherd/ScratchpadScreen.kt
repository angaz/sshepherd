package io.angaz.sshepherd

import android.content.Context
import android.graphics.Typeface
import android.text.InputFilter
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import com.google.android.material.appbar.MaterialToolbar
import org.json.JSONObject

internal data class ScrollbackSnapshot(val pane: String, val text: String, val truncated: Boolean) {
    companion object {
        fun decode(record: JSONObject): ScrollbackSnapshot {
            val pane = record.getString("pane_id")
            val text = record.getString("text")
            require(pane.length in 1..128 && pane.none { it.isISOControl() })
            require(text.toByteArray(Charsets.UTF_8).size <= 256 * 1024)
            return ScrollbackSnapshot(pane, text, record.getBoolean("truncated"))
        }
    }
}

/** Disposable local text: never an InputConnection to the remote terminal. */
internal class ScratchpadScreen(context: Context, retry: () -> Unit, back: () -> Unit) : LinearLayout(context) {
    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()
    private var original: String? = null
    val hasEdits get() = original?.let { it != editor.text.toString() } ?: false
    private val toolbar = MaterialToolbar(context).apply {
        title = "Scrollback scratchpad"
        setTitleTextColor(0xffe6edf3.toInt())
        setNavigationIcon(R.drawable.ic_back); navigationContentDescription = "Back to terminal"
        setNavigationOnClickListener { back() }
        menu.add(0, 1, 0, "Retry").setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_IF_ROOM)
        menu.add(0, 2, 1, "Keyboard").setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_IF_ROOM)
        setOnMenuItemClickListener {
            if (it.itemId == 1) retry() else {
                editor.showSoftInputOnFocus = true
                editor.requestFocus()
                (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(editor, 0)
            }
            true
        }
    }
    private val status = TextView(context).apply {
        textSize = 12f; setTextColor(0xffb5c5cd.toInt())
        setPadding(dp(16), dp(8), dp(16), dp(8))
    }
    val editor = EditText(context).apply {
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        imeOptions = android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI or
            android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        gravity = Gravity.TOP or Gravity.START
        typeface = Typeface.MONOSPACE; textSize = 14f
        setTextColor(0xffe6edf3.toInt()); setBackgroundColor(0xff10141c.toInt())
        setPadding(dp(16), dp(8), dp(16), dp(16))
        isVerticalScrollBarEnabled = true
        showSoftInputOnFocus = false
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        isSaveEnabled = false
        filters = arrayOf(InputFilter.LengthFilter(512 * 1024))
        contentDescription = "Editable local scrollback"
    }
    init {
        orientation = VERTICAL; setBackgroundColor(0xff10141c.toInt())
        isFocusableInTouchMode = true
        addView(toolbar, LayoutParams(-1, dp(56)))
        addView(status, LayoutParams(-1, -2))
        addView(editor, LayoutParams(-1, 0, 1f))
        loading()
    }
    fun loading() {
        status.text = "Loading recent scrollback…"
        editor.isEnabled = false
        toolbar.menu.findItem(1).isEnabled = false
        toolbar.menu.findItem(2).isEnabled = false
    }
    fun display(snapshot: ScrollbackSnapshot) {
        if (original != null) return // Never overwrite local edits with a late response.
        original = snapshot.text; editor.setText(snapshot.text)
        editor.isEnabled = true
        editor.setSelection(editor.length())
        status.text = "${snapshot.pane} · Local copy; edits are not sent. Closing discards edits.\n" +
            "Up to 10,000 lines / 256 KiB; Herdr may return fewer (older versions: 1,000)." +
            if (snapshot.truncated) " Older text omitted." else ""
        toolbar.menu.findItem(1).isVisible = false
        toolbar.menu.findItem(2).isEnabled = true
    }
    fun error(message: String) {
        if (original != null) return
        status.text = message
        toolbar.menu.findItem(1).isEnabled = true
    }
}
