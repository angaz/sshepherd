package io.angaz.sshepherd

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import com.google.android.material.button.MaterialButton

/** Fixed primary keys with a responsive, expandable grid. Never scrolls sideways. */
internal class TerminalControls(
    context: Context,
    primary: List<MaterialButton>,
    private val extra: List<MaterialButton>,
    showKeyboard: () -> Unit
) : LinearLayout(context) {
    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()
    private val grid = GridLayout(context)
    private var columns = 0
    private val panel = object : ScrollView(context) {
        override fun onMeasure(widthSpec: Int, heightSpec: Int) {
            // Usually all keys fit. Short landscape/large-font windows can scroll
            // vertically without squeezing the terminal completely out of view.
            val available = (MeasureSpec.getSize(heightSpec) - dp(120)).coerceAtLeast(dp(48))
            super.onMeasure(widthSpec, MeasureSpec.makeMeasureSpec(minOf(dp(224), available), MeasureSpec.AT_MOST))
        }
    }
    private val expand = iconButton(R.drawable.ic_expand, "Show extra keys") { setExpanded(!expanded) }
    var expanded = false; private set
    init {
        orientation = VERTICAL
        setBackgroundColor(0xff182029.toInt())
        setPadding(dp(6), dp(4), dp(6), dp(4))
        panel.addView(grid)
        panel.visibility = GONE
        addView(panel, LayoutParams(-1, -2))
        val row = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
        (primary + expand + iconButton(R.drawable.ic_keyboard, "Show keyboard", showKeyboard)).forEach {
            row.addView(it, LayoutParams(0, dp(48), 1f).apply { setMargins(dp(2), dp(2), dp(2), dp(2)) })
        }
        addView(row, LayoutParams(-1, -2))
    }
    fun setExpanded(value: Boolean) {
        expanded = value
        panel.visibility = if (value) VISIBLE else GONE
        expand.setIconResource(if (value) R.drawable.ic_collapse else R.drawable.ic_expand)
        expand.contentDescription = if (value) "Hide extra keys" else "Show extra keys"
        expand.isSelected = value
        requestLayout()
    }
    private fun iconButton(icon: Int, description: String, action: () -> Unit) = MaterialButton(context).apply {
        text = ""
        contentDescription = description
        tooltipText = description
        setIconResource(icon)
        iconSize = dp(24); iconPadding = 0
        iconGravity = MaterialButton.ICON_GRAVITY_TEXT_START
        isFocusable = true; isFocusableInTouchMode = false
        setOnClickListener { action() }
    }
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val count = if (MeasureSpec.getSize(widthMeasureSpec) >= dp(600)) 8 else 4
        if (count != columns) {
            columns = count
            grid.removeAllViews()
            grid.columnCount = columns
            extra.forEachIndexed { index, button ->
                grid.addView(button, GridLayout.LayoutParams(
                    GridLayout.spec(index / columns), GridLayout.spec(index % columns, 1f)
                ).apply {
                    width = 0; height = dp(48)
                    setMargins(dp(2), dp(2), dp(2), dp(2))
                    setGravity(Gravity.FILL_HORIZONTAL)
                })
            }
        }
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    }
}
