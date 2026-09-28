package io.angaz.sshepherd;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/** Host-JVM test of the actual C++ JNI surface (not an Android fake). */
public final class GhosttyNative {
    static { System.loadLibrary("sshepherd_terminal"); }
    public static native long create(int cols, int rows);
    public static native void destroy(long id);
    public static native void write(long id, byte[] bytes);
    public static native void resize(long id, int cols, int rows, int cw, int ch);
    public static native byte[] frame(long id);
    public static native byte[] replies(long id);
    public static native byte[] key(long id, int code, int mods, int consumedMods, int action, byte[] text);
    public static native byte[] mouse(long id, int action, int button, double x, double y, int mods);
    public static native boolean mode(long id, int number);
    public static void main(String[] args) {
        long id = create(80, 24);
        if (id == 0) throw new AssertionError("No native handle");
        write(id, "native JNI 🐑\u001b[6n".getBytes(StandardCharsets.UTF_8));
        if (replies(id).length == 0) throw new AssertionError("No VT query response");
        resize(id, 42, 15, 9, 18);
        ByteBuffer buffer = ByteBuffer.wrap(frame(id)).order(ByteOrder.LITTLE_ENDIAN);
        if (buffer.getInt() != 42 || buffer.getInt() != 15) throw new AssertionError("Wrong native grid size");
        if (key(id, 31, 2, 0, 1, new byte[]{'c'})[0] != 3) throw new AssertionError("Ctrl+C");
        write(id, "\u001b[?1000h\u001b[?1006h\u001b[?2004h".getBytes(StandardCharsets.UTF_8));
        if (!mode(id, 2004) || mouse(id, 0, 1, 20, 40, 0).length == 0) throw new AssertionError("Modes/mouse");
        destroy(id);
        destroy(id); // idempotent close; stale handles must not cause use-after-free
        try { frame(id); throw new AssertionError("Stale handle accepted"); }
        catch (IllegalStateException expected) { }
        System.out.println("PASS real JNI create/write/resize/frame/replies/key/mouse/mode/lifetime");
    }
}
