package io.angaz.sshepherd

import android.content.Context
import android.graphics.Typeface
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.appbar.MaterialToolbar

/** Full-screen, virtualized native workspace browser; the terminal stays mounted behind it. */
internal class WorkspaceScreen(context: Context, refresh: () -> Unit, select: (DirectoryRow) -> Unit, back: () -> Unit) : LinearLayout(context) {
    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()
    private val toolbar = MaterialToolbar(context).apply {
        title = "Workspaces & agents"
        setBackgroundColor(0xff10141c.toInt()); setTitleTextColor(0xffe6edf3.toInt())
        setNavigationIcon(R.drawable.ic_back); navigationContentDescription = "Back to terminal"
        setNavigationOnClickListener { back() }
        menu.add(0, 1, 0, "Refresh").setIcon(R.drawable.ic_refresh)
            .setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_ALWAYS)
        setOnMenuItemClickListener { refresh(); true }
    }
    private val status = TextView(context).apply {
        setTextColor(0xffb5c5cd.toInt()); textSize = 14f
        setPadding(dp(16), dp(8), dp(16), dp(8))
    }
    private val adapter = object : RecyclerView.Adapter<RowHolder>() {
        var rows = emptyList<DirectoryRow>()
        var busy = false
        override fun getItemCount() = rows.size
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RowHolder {
            val row = LinearLayout(parent.context).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = RecyclerView.LayoutParams(-1, -2)
                minimumHeight = dp(64)
                isFocusable = true; isFocusableInTouchMode = false
                val typed = context.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground))
                foreground = typed.getDrawable(0); typed.recycle()
            }
            val title = TextView(context).apply { textSize = 16f; setTextColor(0xffe6edf3.toInt()); maxLines = 2 }
            val detail = TextView(context).apply { textSize = 12f; setTextColor(0xffb5c5cd.toInt()); maxLines = 2 }
            row.addView(title); row.addView(detail)
            return RowHolder(row, title, detail)
        }
        override fun onBindViewHolder(holder: RowHolder, position: Int) {
            val row = rows[position]
            holder.itemView.setPadding(dp(if (row.isAgent) 32 else 16), dp(10), dp(16), dp(10))
            holder.title.text = row.title
            holder.title.setTypeface(null, if (row.isAgent) Typeface.NORMAL else Typeface.BOLD)
            holder.detail.text = row.detail
            holder.itemView.contentDescription = "${if (row.isAgent) "Agent" else "Workspace"}: ${row.title}. ${row.detail}"
            holder.itemView.isEnabled = !busy
            holder.itemView.alpha = if (busy) 0.5f else 1f
            holder.itemView.setOnClickListener { if (!busy) select(row) }
        }
    }
    private val list = RecyclerView(context).apply {
        layoutManager = LinearLayoutManager(context)
        adapter = this@WorkspaceScreen.adapter
    }
    init {
        orientation = VERTICAL
        setBackgroundColor(0xff10141c.toInt())
        isFocusable = true; isFocusableInTouchMode = true
        addView(toolbar, LayoutParams(-1, dp(56)))
        addView(status, LayoutParams(-1, -2))
        addView(list, LayoutParams(-1, 0, 1f))
        addView(TextView(context).apply {
            text = "Selecting a row also switches other attached Herdr clients."
            textSize = 12f; setTextColor(0xffb5c5cd.toInt())
            setPadding(dp(16), dp(8), dp(16), dp(8))
        }, LayoutParams(-1, -2))
    }
    fun loading(message: String) {
        status.text = message; adapter.busy = true
        adapter.notifyDataSetChanged()
        toolbar.menu.findItem(1).isEnabled = false
    }
    fun display(rows: List<DirectoryRow>) {
        adapter.rows = rows; adapter.busy = false
        adapter.notifyDataSetChanged()
        status.text = if (rows.isEmpty()) "No workspaces." else "Tap a workspace or agent to switch."
        toolbar.menu.findItem(1).isEnabled = true
    }
    fun error(message: String) {
        status.text = message
        // Stale rows must not act while disconnected or after a failed refresh.
        adapter.rows = emptyList(); adapter.busy = false; adapter.notifyDataSetChanged()
        toolbar.menu.findItem(1).isEnabled = true
    }
    private class RowHolder(view: LinearLayout, val title: TextView, val detail: TextView) : RecyclerView.ViewHolder(view)
}
