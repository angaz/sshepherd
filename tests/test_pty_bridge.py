import importlib.util
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import time
import unittest

BRIDGE = Path(__file__).resolve().parents[1] / 'native/pty_bridge.py'
spec = importlib.util.spec_from_file_location('bridge', BRIDGE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def frame(kind, data):
    return struct.pack('>BI', kind, len(data)) + data


class Framing(unittest.TestCase):
    def test_fragmentation_and_coalescing(self):
        wire = frame(1, '🐑\x03'.encode()) + frame(2, struct.pack('>HH', 80, 24))
        buffer = bytearray()
        frames = []
        for byte in wire:
            buffer.append(byte)
            parsed = bridge.pop_frame(buffer)
            if parsed:
                frames.append(parsed)
        self.assertEqual(frames, [(1, '🐑\x03'.encode()), (2, struct.pack('>HH', 80, 24))])
        self.assertEqual(buffer, b'')

    def test_invalid_frames(self):
        for data in (struct.pack('>BI', 1, 65537), frame(9, b''), frame(2, b'x')):
            with self.assertRaises(ValueError):
                bridge.pop_frame(bytearray(data))
        with self.assertRaises(ValueError):
            bridge.size(struct.pack('>HH', 0, 24))

    def test_image_chunks_stage_private_file_then_drop_through_herdr(self):
        upload = bridge.ImageUpload()
        directory = Path(upload.directory.name)
        try:
            data = b'\x89PNG\r\n\x1a\nfixture'
            self.assertEqual(upload.frame(3, struct.pack('>I', len(data)) + b'png'), b'')
            upload.frame(4, data[:5])
            upload.frame(4, data[5:])
            drop = upload.frame(5, b'')
            self.assertEqual(drop, b'\x1b[200~' + upload.path.encode() + b'\x1b[201~')
            self.assertEqual(Path(upload.path).read_bytes(), data)
            self.assertEqual(Path(upload.path).stat().st_mode & 0o777, 0o600)
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        finally:
            upload.close()
        self.assertFalse(directory.exists())

    def test_invalid_image_metadata_order_length_and_quota(self):
        upload = bridge.ImageUpload()
        try:
            for kind, body in [(4, b'x'), (5, b''), (3, struct.pack('>I', 1) + b'exe'),
                               (3, struct.pack('>I', bridge.ImageUpload.LIMIT + 1) + b'png')]:
                with self.assertRaises(ValueError): upload.frame(kind, body)
            upload.frame(3, struct.pack('>I', 2) + b'png')
            with self.assertRaises(ValueError): upload.frame(5, b'')
            with self.assertRaises(ValueError): upload.frame(4, b'abc')
            with self.assertRaises(ValueError): upload.frame(3, struct.pack('>I', 1) + b'png')
            upload.frame(4, b'ab'); upload.frame(5, b'')
            upload.total = upload.SESSION_LIMIT
            with self.assertRaises(ValueError): upload.frame(3, struct.pack('>I', 1) + b'png')
        finally:
            upload.close()

    def test_real_pty_input_unicode_resize_and_eof(self):
        # Fake only the Herdr executable; run the real bridge/PTY machinery.
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'herdr'
            fake.write_text(f'#!{sys.executable}\n' + '''import os, signal, tty
assert os.sys.argv[1:] == ['--session', 'default']
assert os.environ['HERDR_REMOTE_KEYBINDINGS'] == 'server'
tty.setraw(0)
def size(*args):
    s = os.get_terminal_size(0)
    os.write(1, f'SIZE={s.columns}x{s.lines}\\n'.encode())
signal.signal(signal.SIGWINCH, size)
size()
while True:
    data = os.read(0, 4096)
    if not data: break
    os.write(1, b'INPUT=' + data + b'\\n')
''')
            fake.chmod(0o700)
            env = {**os.environ, 'PATH': directory + os.pathsep + os.environ['PATH']}
            proc = subprocess.Popen([sys.executable, '-u', str(BRIDGE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            output = bytearray()

            def expect(value):
                deadline = time.monotonic() + 5
                while value not in output:
                    if time.monotonic() >= deadline:
                        self.fail(f'timed out waiting for {value!r}: {output!r}')
                    if select.select([proc.stdout], [], [], .1)[0]:
                        chunk = os.read(proc.stdout.fileno(), 65536)
                        if not chunk:
                            self.fail(f'bridge exited: {proc.stderr.read()!r}')
                        output.extend(chunk)
            try:
                proc.stdin.write(frame(2, struct.pack('>HH', 80, 24)))
                proc.stdin.flush()
                expect(b'SIZE=80x24')
                payload = 'hello 🐑\x03\x1b[<0;2;3M'.encode()
                proc.stdin.write(frame(1, payload))
                proc.stdin.flush()
                expect(b'INPUT=' + payload)
                proc.stdin.write(frame(2, struct.pack('>HH', 42, 15)))
                proc.stdin.flush()
                expect(b'SIZE=42x15')
                proc.stdin.close()
                self.assertEqual(proc.wait(timeout=5), 0)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                for stream in (proc.stdin, proc.stdout, proc.stderr):
                    stream.close()


if __name__ == '__main__':
    unittest.main()
