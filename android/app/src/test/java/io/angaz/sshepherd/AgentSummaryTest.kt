package io.angaz.sshepherd

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class AgentSummaryTest {
    private fun counts() = JSONObject("""{"working":1,"blocked":0,"idle":13,"done":0,"unknown":0}""")
    @Test fun onlyNonzeroCountsAppearInStableOrder() {
        assertEquals("1 working · 13 idle", AgentSummary.decode(counts()).text)
        assertEquals("No agents", AgentSummary.decode(counts().put("working", 0).put("idle", 0)).text)
        assertEquals("1 working · 2 blocked · 13 idle · 1 unknown",
            AgentSummary.decode(counts().put("blocked", 2).put("unknown", 1)).text)
    }
    @Test fun malformedOrUnboundedCountsAreRejected() {
        for (record in listOf(counts().put("working", -1), counts().put("idle", 4097),
            counts().put("working", 4096), counts().apply { remove("done") }, counts().put("idle", "oops"))) {
            assertThrows(Exception::class.java) { AgentSummary.decode(record) }
        }
    }
}
