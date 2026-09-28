package io.angaz.sshepherd

object Native {
    init { System.loadLibrary("sshepherd") }
    @JvmStatic external fun open(host: String, token: String): Long
    @JvmStatic external fun send(id: Long, data: ByteArray): Boolean
    @JvmStatic external fun poll(id: Long): String
    @JvmStatic external fun close(id: Long)
}
