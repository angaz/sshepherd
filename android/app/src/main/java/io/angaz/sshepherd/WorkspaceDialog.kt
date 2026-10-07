package io.angaz.sshepherd

import android.content.Context
import android.graphics.Typeface
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.dialog.MaterialAlertDialogBuilder

/** Virtualized native rows, not the remote terminal sidebar. */
internal class WorkspaceDialog(private val context: Context, refresh: () -> Unit, select: (DirectoryRow) -> Unit, closed: () -> Unit) {
    private fun dp(n: Int) = (n * context.resources.displayMetrics.density).toInt()
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
        adapter = this@WorkspaceDialog.adapter
    }
    private val dialog: AlertDialog
    init {
        val content = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(status, LinearLayout.LayoutParams(-1, -2))
            addView(list, LinearLayout.LayoutParams(-1,
                dp(minOf(context.resources.configuration.screenHeightDp / 2,
                    context.resources.configuration.screenHeightDp - 220).coerceIn(80, 400))))
            addView(TextView(context).apply {
                text = "Selecting a row also switches other attached Herdr clients."
                textSize = 12f; setTextColor(0xffb5c5cd.toInt())
                setPadding(dp(16), dp(8), dp(16), dp(8))
            })
        }
        dialog = MaterialAlertDialogBuilder(context).setTitle("Workspaces & agents").setView(content)
            .setNegativeButton("Close", null).setNeutralButton("Refresh", null).create()
        dialog.setOnDismissListener { closed() }
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener { refresh() }
        }
    }
    fun show() {
        dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
        dialog.show()
    }
    fun dismiss() = dialog.dismiss()
    fun loading(message: String) {
        status.text = message; adapter.busy = true
        adapter.notifyDataSetChanged()
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL)?.isEnabled = false
    }
    fun display(rows: List<DirectoryRow>) {
        adapter.rows = rows; adapter.busy = false
        adapter.notifyDataSetChanged()
        status.text = if (rows.isEmpty()) "No workspaces." else "Tap a workspace or agent to switch."
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL)?.isEnabled = true
    }
    fun error(message: String) {
        status.text = message
        // Stale rows must not act while disconnected or after a failed refresh.
        adapter.rows = emptyList(); adapter.busy = false; adapter.notifyDataSetChanged()
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL)?.isEnabled = true
    }
    private class RowHolder(view: LinearLayout, val title: TextView, val detail: TextView) : RecyclerView.ViewHolder(view)
}
