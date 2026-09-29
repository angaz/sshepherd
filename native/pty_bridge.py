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
import tempfile

MAX_FRAME = 65536


def pop_frame(buffer):
    if len(buffer) < 5:
        return None
    kind, length = struct.unpack('>BI', buffer[:5])
    if length > MAX_FRAME:
        raise ValueError('oversized input frame')
    if kind not in (1, 2, 3, 4, 5) or (kind == 2 and length != 4) or (kind == 5 and length != 0):
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


class ImageUpload:
    """Stage a bounded image for Herdr's native file-drop -> ClipboardImage path.

    Only generated paths enter the PTY. Herdr reads this staging file and sends
    its existing ClipboardImage message to the pane selected by that frontend.
    """
    LIMIT = 16 * 1024 * 1024
    SESSION_LIMIT = 64 * 1024 * 1024

    def __init__(self):
        self.directory = tempfile.TemporaryDirectory(prefix='sshepherd-images-', dir='/tmp')
        self.file = None
        self.path = None
        self.remaining = 0
        self.total = 0

    def frame(self, kind, body):
        if kind == 3:
            if self.file is not None or len(body) not in range(7, 9):
                raise ValueError('invalid image start')
            length = struct.unpack('>I', body[:4])[0]
            extension = body[4:].decode('ascii')
            if extension not in ('png', 'jpg', 'gif', 'webp', 'bmp') or not 0 < length <= self.LIMIT:
                raise ValueError('invalid image metadata')
            if self.total + length > self.SESSION_LIMIT:
                raise ValueError('image session quota reached; reconnect')
            self.total += length
            self.remaining = length
            fd, self.path = tempfile.mkstemp(suffix='.' + extension, dir=self.directory.name)
            self.file = os.fdopen(fd, 'wb')
        elif kind == 4:
            if self.file is None or not body or len(body) > self.remaining:
                raise ValueError('invalid image chunk')
            self.file.write(body)
            self.remaining -= len(body)
        elif kind == 5:
            if self.file is None or self.remaining or body:
                raise ValueError('incomplete image')
            self.file.close()
            self.file = None
            # Keep the file until detach: Herdr consumes the drop asynchronously.
            return b'\x1b[200~' + self.path.encode('ascii') + b'\x1b[201~'
        return b''

    def close(self):
        if self.file is not None:
            self.file.close()
        self.directory.cleanup()


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
        # Enable Herdr's remote-image file-drop bridge while retaining the
        # server's keybindings. No separate upload service or shell command.
        os.environ['HERDR_REMOTE_KEYBINDINGS'] = 'server'
        os.execvp('herdr', ['herdr', '--session', 'default'])
    pending = bytearray()
    images = ImageUpload()
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
                elif kind == 2:
                    fcntl.ioctl(master, termios.TIOCSWINSZ, size(body))
                else:
                    drop = images.frame(kind, body)
                    if drop:
                        pending.extend(drop)
                        if len(pending) > 1024 * 1024:
                            raise ValueError('PTY input backlog full')
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
        images.close()


if __name__ == '__main__':
    main()
