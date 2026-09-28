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
        for data in (struct.pack('>BI', 1, 65537), frame(4, b''), frame(2, b'x')):
            with self.assertRaises(ValueError):
                bridge.pop_frame(bytearray(data))
        with self.assertRaises(ValueError):
            bridge.size(struct.pack('>HH', 0, 24))

    def test_real_pty_input_unicode_resize_and_eof(self):
        # Fake only the Herdr executable; run the real bridge/PTY machinery.
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'herdr'
            fake.write_text(f'#!{sys.executable}\n' + '''import os, signal, tty
assert os.sys.argv[1:] == ['--session', 'default']
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
