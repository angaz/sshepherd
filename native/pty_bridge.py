"""Runs remotely, in memory. stdin: [type:u8][length:u32 BE][body]; stdout: VT bytes.
Only the Herdr *client* owns this PTY; disconnecting never kills the Herdr server.
"""
import errno
import fcntl
import os
import pty
import selectors
import signal
import struct
import sys
import termios

MAX_FRAME = 65536


def pop_frame(buffer):
    if len(buffer) < 5:
        return None
    kind, length = struct.unpack('>BI', buffer[:5])
    if length > MAX_FRAME:
        raise ValueError('oversized input frame')
    if kind not in (1, 2) or (kind == 2 and length != 4):
        raise ValueError('invalid input frame')
    if len(buffer) < 5 + length:
        return None
    body = bytes(buffer[5:5 + length])
    del buffer[:5 + length]
    return kind, body


def size(body):
    cols, rows = struct.unpack('>HH', body)
    if not 2 <= cols <= 500 or not 2 <= rows <= 300:
        raise ValueError('invalid terminal dimensions')
    return struct.pack('HHHH', rows, cols, 0, 0)


def main():
    # Wait for the phone's geometry before starting Herdr, avoiding a 0x0 PTY.
    buffer = bytearray()
    initial = None
    while initial is None:
        chunk = os.read(0, 65536)
        if not chunk:
            return
        buffer.extend(chunk)
        initial = pop_frame(buffer)
    if initial[0] != 2:
        raise ValueError('first frame must be resize')
    geometry = size(initial[1])
    pid, master = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, geometry)
        os.environ['TERM'] = 'xterm-256color'
        os.environ['COLORTERM'] = 'truecolor'
        os.execvp('herdr', ['herdr', '--session', 'default'])
    pending = bytearray()
    os.set_blocking(master, False)
    selector = selectors.DefaultSelector()
    selector.register(0, selectors.EVENT_READ)
    selector.register(master, selectors.EVENT_READ)
    try:
        while True:
            while True:
                parsed = pop_frame(buffer)
                if parsed is None:
                    break
                kind, body = parsed
                if kind == 1:
                    pending.extend(body)
                    if len(pending) > 1024 * 1024:
                        raise ValueError('PTY input backlog full')
                else:
                    fcntl.ioctl(master, termios.TIOCSWINSZ, size(body))
            selector.modify(master, selectors.EVENT_READ | (selectors.EVENT_WRITE if pending else 0))
            for key, events in selector.select():
                if key.fd == 0:
                    chunk = os.read(0, 65536)
                    if not chunk:
                        return
                    buffer.extend(chunk)
                else:
                    if events & selectors.EVENT_READ:
                        try:
                            output = os.read(master, 65536)
                        except OSError as error:
                            if error.errno == errno.EIO:
                                return
                            raise
                        if not output:
                            return
                        # stdout is a pipe, not the PTY; preserve every output byte.
                        view = memoryview(output)
                        while view:
                            view = view[os.write(1, view):]
                    if events & selectors.EVENT_WRITE and pending:
                        del pending[:os.write(master, pending)]
    finally:
        selector.close()
        os.close(master)
        try:
            os.kill(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)


if __name__ == '__main__':
    main()
