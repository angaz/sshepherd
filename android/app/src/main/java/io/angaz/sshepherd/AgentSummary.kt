package io.angaz.sshepherd

import org.json.JSONObject

/** Bounded, text-only counts from the read-only Herdr snapshot API. */
internal data class AgentSummary(val counts: List<Pair<String, Int>>) {
    val text: String get() = counts.filter { it.second > 0 }
        .joinToString(" · ") { "${it.second} ${it.first}" }.ifEmpty { "No agents" }
    companion object {
        fun decode(record: JSONObject): AgentSummary {
            val counts = listOf("working", "blocked", "idle", "done", "unknown").map { name ->
                val count = record.getInt(name)
                require(count in 0..4096)
                name to count
            }
            require(counts.sumOf { it.second } <= 4096)
            return AgentSummary(counts)
        }
    }
}
