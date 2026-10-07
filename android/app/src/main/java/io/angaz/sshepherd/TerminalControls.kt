package io.angaz.sshepherd

import android.content.Context
import android.content.res.ColorStateList
import android.view.Gravity
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import com.google.android.material.button.MaterialButton

/** Two compact, always-visible key rows with matching expandable extra keys. */
internal class TerminalControls(
    context: Context,
    primary: List<List<MaterialButton>>,
    private val extra: List<MaterialButton>,
    showKeyboard: () -> Unit
) : LinearLayout(context) {
    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()
    private val grid = GridLayout(context)
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
        setPadding(dp(4), dp(2), dp(4), dp(2))
        grid.columnCount = 7
        extra.forEachIndexed { index, button ->
            compact(button)
            grid.addView(button, GridLayout.LayoutParams(
                GridLayout.spec(index / 7), GridLayout.spec(index % 7, 1f)
            ).apply {
                width = 0; height = dp(40)
                setGravity(Gravity.FILL_HORIZONTAL)
            })
        }
        panel.addView(grid)
        panel.visibility = GONE
        addView(panel, LayoutParams(-1, -2))
        require(primary.size == 2 && primary.all { it.size == 6 })
        val trailing = listOf(expand, iconButton(R.drawable.ic_keyboard, "Show keyboard", showKeyboard))
        primary.forEachIndexed { index, keys ->
            val row = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
            (keys + trailing[index]).forEach {
                compact(it)
                row.addView(it, LayoutParams(0, dp(40), 1f))
            }
            addView(row, LayoutParams(-1, -2))
        }
    }
    fun setExpanded(value: Boolean) {
        expanded = value
        panel.visibility = if (value) VISIBLE else GONE
        expand.setIconResource(if (value) R.drawable.ic_collapse else R.drawable.ic_expand)
        expand.contentDescription = if (value) "Hide extra keys" else "Show extra keys"
        expand.tooltipText = expand.contentDescription
        expand.isSelected = value
        requestLayout()
    }
    private fun compact(button: MaterialButton) = button.apply {
        minWidth = 0; minimumWidth = 0
        minHeight = 0; minimumHeight = 0
        insetTop = 0; insetBottom = 0
        setPadding(0, 0, 0, 0)
        setSingleLine(true)
        textSize = 12f; isAllCaps = true
        setTextColor(0xffe6edf3.toInt())
        backgroundTintList = ColorStateList(
            arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
            intArrayOf(0xff36584e.toInt(), android.graphics.Color.TRANSPARENT)
        )
        iconTint = ColorStateList.valueOf(0xffe6edf3.toInt())
        iconSize = dp(20)
        tooltipText = contentDescription ?: text
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
}
