package io.angaz.sshepherd

import android.content.Context
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class HostStoreTest {
    @Test fun editsAndEmptyInventoryPersistWithoutRestoringDeletedDefaults() {
        val app = RuntimeEnvironment.getApplication()
        app.getSharedPreferences("hosts", Context.MODE_PRIVATE).edit().clear().commit()
        val store = HostStore(app)
        assertEquals(6, store.read().size)
        val host = HostStore.entry(" My workstation ", "192.0.2.10")
        store.save(listOf(host))
        assertEquals(listOf(host), HostStore(app).read())
        val edited = HostStore.entry("Office", "[2001:db8::123]", host.id)
        store.save(listOf(edited))
        assertEquals("2001:db8::123", HostStore(app).read().single().address)
        assertEquals(host.id, HostStore(app).read().single().id)
        store.save(emptyList())
        assertTrue(HostStore(app).read().isEmpty())
    }
    @Test fun validatesNamesAndAddressesWithoutResolvingDns() {
        assertEquals("host-b.example.invalid", HostStore.entry("Desktop", " Host-B.Example.Invalid. ").address)
        assertEquals("my-server", HostStore.entry("Server", "my-server").address)
        for (address in listOf("", "https://host", "host:7443", "host/path", "host;ls", "a..b", "999.1.2.3", "127.1", "01.2.3.4", "[2001:db8::123]:7443")) {
            assertThrows(Exception::class.java) { HostStore.entry("Server", address) }
        }
        assertThrows(Exception::class.java) { HostStore.entry("", "server") }
        assertThrows(Exception::class.java) { HostStore.entry("bad\nname", "server") }
    }
}
