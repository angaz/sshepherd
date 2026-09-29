package io.angaz.sshepherd

import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class ContentReadJobTest {
    @Test fun stalledPipeIsCancelledAndPermissionReleasedExactlyOnce() {
        val pipe = PipedInputStream()
        val writer = PipedOutputStream(pipe) // Open pipe, no bytes and no EOF.
        val opened = CountDownLatch(1)
        val released = AtomicInteger()
        val cancelled = AtomicInteger()
        val results = AtomicInteger()
        val job = ContentReadJob({ opened.countDown(); pipe }, { cancelled.incrementAndGet() },
            { released.incrementAndGet() }, { results.incrementAndGet() })
        val thread = Thread(job).apply { isDaemon = true; start() }
        try {
            assertTrue(opened.await(2, TimeUnit.SECONDS))
            job.cancel()
            thread.join(2000)
            assertFalse(thread.isAlive)
            job.cancel()
            assertEquals(1, released.get())
            assertEquals(0, results.get())
            val nextResults = mutableListOf<PasteContent>()
            ContentReadJob({ "next file".byteInputStream() }, {}, {}, { nextResults.add(it.getOrThrow()) }).run()
            assertEquals(listOf(PasteContent.Text("next file")), nextResults)
        } finally { writer.close(); pipe.close() }
    }
    @Test fun cancellationBeforeStartReleasesGrantWithoutOpening() {
        val released = AtomicInteger()
        var opened = false
        val job = ContentReadJob({ opened = true; "never".byteInputStream() }, {}, { released.incrementAndGet() }, { fail("late result") })
        job.cancel(); job.run()
        assertFalse(opened)
        assertEquals(1, released.get())
    }
    @Test fun failedOpenReleasesPermission() {
        val released = AtomicInteger()
        var failure = false
        ContentReadJob({ throw java.io.IOException("provider unavailable") }, {}, { released.incrementAndGet() }, { failure = it.isFailure }).run()
        assertTrue(failure)
        assertEquals(1, released.get())
    }
}
