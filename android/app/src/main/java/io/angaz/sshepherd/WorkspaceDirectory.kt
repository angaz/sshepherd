package io.angaz.sshepherd

import org.json.JSONObject

internal data class DirectoryRow(val id: String, val title: String, val detail: String, val isAgent: Boolean)
internal object WorkspaceDirectory {
    private fun JSONObject.label(key: String): String = if (isNull(key)) "" else optString(key).take(512)
        .filter { !it.isISOControl() }
    fun rows(record: JSONObject): List<DirectoryRow> {
        val workspaces = record.getJSONArray("workspaces")
        val agents = record.getJSONArray("agents")
        require(workspaces.length() <= 512 && agents.length() <= 4096)
        val children = mutableMapOf<String, MutableList<DirectoryRow>>()
        repeat(agents.length()) {
            val agent = agents.getJSONObject(it)
            val workspace = agent.label("workspace_id")
            val pane = agent.label("pane_id")
            val kind = agent.label("display_agent").ifBlank { agent.label("agent") }
            // Snapshot agents includes ordinary shells; only recognized agents
            // belong in this list. Workspaces themselves remain selectable.
            if (pane.isNotBlank() && kind.isNotBlank()) {
                val title = agent.label("title").ifBlank { agent.label("terminal_title_stripped") }
                    .ifBlank { agent.label("name") }.ifBlank { kind }
                val status = agent.label("agent_status").ifBlank { "unknown" }
                children.getOrPut(workspace) { mutableListOf() }.add(
                    DirectoryRow(pane, title, "$kind · $status · ${agent.label("tab_id")}", true)
                )
            }
        }
        return buildList {
            repeat(workspaces.length()) {
                val workspace = workspaces.getJSONObject(it)
                val id = workspace.label("workspace_id")
                require(id.isNotBlank())
                val title = workspace.label("label").ifBlank { id }
                add(DirectoryRow(id, title,
                    "${workspace.optInt("tab_count")} tabs · ${workspace.optInt("pane_count")} panes · ${workspace.label("agent_status")}", false))
                addAll(children[id].orEmpty())
            }
        }
    }
}
