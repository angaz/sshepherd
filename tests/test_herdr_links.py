"""Opt-in real Herdr test; every process/socket lives in a temporary config.
Run: SSHEPHERD_TEST_HERDR_LINKS=1 python3 -m unittest discover -s tests -p test_herdr_links.py -v
"""
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bridge_test_helpers', ROOT / 'tests/test_pty_bridge.py')
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)


@unittest.skipUnless(os.environ.get('SSHEPHERD_TEST_HERDR_LINKS') == '1' and shutil.which('herdr'),
                     'requires opt-in and installed Herdr')
class HerdrLinks(unittest.TestCase):
    def test_mouse_capture_hides_osc8_but_api_returns_destination_and_mouse_still_works(self):
        with tempfile.TemporaryDirectory(prefix='sshepherd-herdr-links-') as directory:
            root = Path(directory)
            for name in ('home', 'runtime', 'state', 'data', 'tmp'):
                (root / name).mkdir(mode=0o700)
            shell = root / 'shell'
            shell.write_text(f'#!{sys.executable}\n' + '''import os, sys, time, tty
tty.setraw(0)
time.sleep(0.2)
sys.stdout.write("\\x1b[?1000h\\x1b[?1006h\\x1b]8;;https://example.com\\x1b\\\\Open example.com\\x1b]8;;\\x1b\\\\")
sys.stdout.flush()
data = bytearray()
while True:
    data.extend(os.read(0, 1024))
    if b'\\x1b[<0;5;1M' in data and b'\\x1b[<0;5;1m' in data:
        os.write(1, b'\\r\\nMOUSE_FORWARDED')
        data.clear()
''')
            shell.chmod(0o700)
            config = root / 'config.toml'
            config.write_text(f'onboarding = false\n[ui]\nmouse_capture = true\n'
                              f'[terminal]\ndefault_shell = "{shell}"\n'
                              '[update]\nversion_check = false\nmanifest_check = false\n')
            env = {k: v for k, v in os.environ.items() if not k.startswith('HERDR_')}
            env.update(HOME=str(root / 'home'), XDG_RUNTIME_DIR=str(root / 'runtime'),
                       XDG_CONFIG_HOME=directory, XDG_STATE_HOME=str(root / 'state'),
                       XDG_DATA_HOME=str(root / 'data'), TMPDIR=str(root / 'tmp'), HERDR_CONFIG_PATH=str(config))
            process = subprocess.Popen([sys.executable, str(ROOT / 'native/pty_bridge.py')],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            decoder = helpers.OutputFrames()
            vt = bytearray()

            def until(predicate):
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    remaining = deadline - time.monotonic()
                    if not select.select([process.stdout], [], [], max(0, remaining))[0]:
                        break
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        self.fail('bridge exited before response')
                    for kind, body in decoder.push(chunk):
                        if kind == 1:
                            vt.extend(body)
                        if predicate(kind, body):
                            return body
                self.fail('timed out waiting for isolated Herdr')

            try:
                process.stdin.write(helpers.frame(2, struct.pack('>HH', 60, 30))); process.stdin.flush()
                # Terminal rendering may split a label across ANSI patches.
                until(lambda kind, body: kind == 1 and b'com' in vt)
                self.assertNotIn(b'https://example.com', vt)
                request = {'id': 'link', 'action': 'link', 'line': 'Open example.com',
                           'col': 4, 'row': 0, 'cols': 60, 'rows': 28}
                process.stdin.write(helpers.frame(6, json.dumps(request).encode())); process.stdin.flush()
                reply = json.loads(until(lambda kind, body: kind == 2))
                self.assertEqual(reply['error'], '')
                self.assertEqual(reply['link'], {'url': 'https://example.com', 'handled': False, 'fallback': False})
                process.stdin.write(helpers.frame(1, b'\x1b[<0;5;3M\x1b[<0;5;3m')); process.stdin.flush()
                until(lambda kind, body: kind == 1 and b'MOUSE_FORWARDED' in vt)
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=4)
                process.stdout.close(); process.stderr.close()
                subprocess.run(['herdr', '--session', 'default', 'server', 'stop'], env=env,
                               capture_output=True, timeout=10, check=False)
