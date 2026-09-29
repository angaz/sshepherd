package io.angaz.sshepherd

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal data class HostEntry(val id: String, val name: String, val address: String)

/** User-managed inventory, independent of connection/reachability state. */
internal class HostStore(context: Context) {
    private val prefs = context.getSharedPreferences("hosts", Context.MODE_PRIVATE)
    fun read(): List<HostEntry> {
        val saved = prefs.getString("inventory", null) ?: return defaults()
        return try {
            val array = JSONArray(saved)
            require(array.length() <= 100)
            (0 until array.length()).map { index ->
                val item = array.getJSONObject(index)
                entry(item.getString("name"), item.getString("address"), item.getString("id"))
            }.also { require(it.map { host -> host.id }.distinct().size == it.size) }
        } catch (_: Exception) { defaults() }
    }
    fun save(hosts: List<HostEntry>) {
        require(hosts.size <= 100) { "Maximum 100 hosts" }
        require(hosts.map { it.id }.distinct().size == hosts.size)
        val array = JSONArray()
        hosts.forEach { host ->
            val valid = entry(host.name, host.address, host.id)
            array.put(JSONObject().put("id", valid.id).put("name", valid.name).put("address", valid.address))
        }
        check(prefs.edit().putString("inventory", array.toString()).commit()) { "Could not save hosts" }
    }
    companion object {
        fun defaults() = listOf("host-a", "host-b", "host-c", "host-d", "host-e", "host-f")
            .map { HostEntry(it, it, "$it.example.invalid") }
        fun entry(name: String, address: String, id: String = UUID.randomUUID().toString()): HostEntry {
            val label = name.trim()
            require(label.isNotEmpty() && label.length <= 64 && label.none { it.isISOControl() }) { "Enter a name (1–64 characters)" }
            require(id.isNotEmpty() && id.length <= 64)
            var target = address.trim().removeSuffix(".").lowercase(java.util.Locale.ROOT)
            if (target.startsWith("[") && target.endsWith("]")) target = target.substring(1, target.length - 1)
            require(target.isNotEmpty() && target.length <= 253) { "Enter a hostname or IP address" }
            if (':' in target) {
                require(target.all { it in "0123456789abcdef:." } &&
                    java.net.InetAddress.getByName(target) is java.net.Inet6Address) { "Invalid IPv6 address; do not include a port" }
            } else if (target.all { it.isDigit() || it == '.' }) {
                val parts = target.split('.')
                require(parts.size == 4 && parts.all { it.length in 1..3 && (it.toIntOrNull() ?: -1) in 0..255 && (it.length == 1 || !it.startsWith('0')) }) { "Invalid IPv4 address" }
            } else {
                require(target.split('.').all { it.length in 1..63 && it.first().isLetterOrDigit() && it.last().isLetterOrDigit() &&
                    it.all { char -> char in 'a'..'z' || char in '0'..'9' || char == '-' } }) { "Use a hostname or IP only, without a URL, path or port" }
            }
            return HostEntry(id, label, target)
        }
    }
}
