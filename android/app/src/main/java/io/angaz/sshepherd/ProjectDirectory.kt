package io.angaz.sshepherd

import org.json.JSONObject

internal object ProjectDirectory {
    fun decode(response: JSONObject): List<String> {
        val values = response.getJSONArray("projects")
        require(values.length() <= 513)
        return List(values.length()) { index ->
            val value = values.get(index)
            require(value is String && value.isNotBlank() && value.toByteArray(Charsets.UTF_8).size <= 256 &&
                value.none { it.isISOControl() })
            value
        }
    }
}
