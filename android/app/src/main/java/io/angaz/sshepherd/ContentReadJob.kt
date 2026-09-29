package io.angaz.sshepherd

import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Owns permission and stream lifetimes even if cancellation precedes opening. */
internal class ContentReadJob(
    private val open: () -> InputStream,
    private val cancelProvider: () -> Unit,
    private val release: () -> Unit,
    private val complete: (Result<PasteContent>) -> Unit
) : Runnable {
    private val cancelled = AtomicBoolean()
    private val released = AtomicBoolean()
    private val stream = AtomicReference<InputStream?>()
    private val worker = AtomicReference<Thread?>()
    private fun releaseOnce() { if (released.compareAndSet(false, true)) runCatching { release() } }
    fun cancel() {
        cancelled.set(true)
        worker.get()?.interrupt()
        // Revoke grants even when a provider ignores cancellation or never opens.
        releaseOnce()
        stream.getAndSet(null)?.let { runCatching { it.close() } }
        runCatching { cancelProvider() }
    }
    override fun run() {
        worker.set(Thread.currentThread())
        val result = runCatching {
            check(!cancelled.get())
            val input = open()
            stream.set(input)
            input.use {
                check(!cancelled.get())
                ContentFiles.read(it)
            }
        }
        stream.set(null)
        worker.set(null)
        releaseOnce()
        if (!cancelled.get()) complete(result)
    }
}
