package io.angaz.sshepherd

/** Native libghostty-vt, statically linked into libsshepherd_terminal.so. */
object GhosttyNative {
    init { System.loadLibrary("sshepherd_terminal") }
    @JvmStatic external fun create(cols: Int, rows: Int): Long
    @JvmStatic external fun destroy(id: Long)
    @JvmStatic external fun write(id: Long, bytes: ByteArray)
    @JvmStatic external fun resize(id: Long, cols: Int, rows: Int, cellWidth: Int, cellHeight: Int)
    @JvmStatic external fun frame(id: Long): ByteArray
    @JvmStatic external fun hyperlink(id: Long, x: Int, y: Int): ByteArray
    @JvmStatic external fun replies(id: Long): ByteArray
    @JvmStatic external fun clipboard(id: Long): ByteArray?
    @JvmStatic external fun key(id: Long, code: Int, mods: Int, consumedMods: Int, action: Int, utf8: ByteArray): ByteArray
    @JvmStatic external fun mouse(id: Long, action: Int, button: Int, x: Double, y: Double, mods: Int): ByteArray
    @JvmStatic external fun mode(id: Long, number: Int): Boolean
}
