package io.angaz.sshepherd

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class WorkspaceDirectoryTest {
    @Test fun groupsRecognizedAgentsUnderEveryWorkspaceAndIgnoresShells() {
        val rows = WorkspaceDirectory.rows(JSONObject("""{
            "workspaces":[{"workspace_id":"w1","label":"Project","tab_count":2,"pane_count":3,"agent_status":"working"},
                          {"workspace_id":"w2","label":"Empty","tab_count":1,"pane_count":1}],
            "agents":[{"workspace_id":"w1","pane_id":"w1:p1","tab_id":"w1:t1","agent":"pi","title":"Fix tests","agent_status":"blocked"},
                      {"workspace_id":"w1","pane_id":"w1:p2","agent":null,"title":"shell"}]
        }"""))
        assertEquals(listOf("w1", "w1:p1", "w2"), rows.map { it.id })
        assertEquals("Fix tests", rows[1].title)
        assertTrue(rows[1].isAgent)
        assertTrue(rows[1].detail.contains("blocked"))
        assertFalse(rows[0].isAgent)
    }
    @Test fun handlesEmptyNamesNullMetadataAndControlCharacters() {
        val rows = WorkspaceDirectory.rows(JSONObject("""{
          "workspaces":[{"workspace_id":"w1","label":null}],
          "agents":[{"workspace_id":"w1","pane_id":"w1:p1","display_agent":"Pi","title":"\u001bTask\n","agent_status":null}]
        }"""))
        assertEquals("w1", rows[0].title)
        assertEquals("Task", rows[1].title)
        assertTrue(rows[1].detail.contains("unknown"))
    }
    @Test fun directoryFrameContainsJsonNotTerminalKeystrokes() {
        val record = JSONObject().put("id", "request").put("action", "workspace").put("workspace_id", "w1")
        val wire = PtyFrames.directory(record)
        val buffer = java.nio.ByteBuffer.wrap(wire)
        assertEquals(6, buffer.get().toInt())
        assertEquals(wire.size - 5, buffer.int)
        val data = ByteArray(buffer.remaining()); buffer.get(data)
        assertEquals("w1", JSONObject(String(data, Charsets.UTF_8)).getString("workspace_id"))
    }
}
