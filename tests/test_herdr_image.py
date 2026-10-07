"""Opt-in real Herdr integration, isolated from all personal sessions and files.
SSHEPHERD_TEST_HERDR=/absolute/path/to/herdr python3 -m unittest discover -s tests -v
"""
import base64
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import time
import unittest

from test_pty_bridge import BRIDGE, frame, OutputFrames


@unittest.skipUnless(os.environ.get('SSHEPHERD_TEST_HERDR'), 'real Herdr binary not requested')
class HerdrImage(unittest.TestCase):
    def test_native_clipboard_image_routes_staged_path_to_pane(self):
        binary = os.environ['SSHEPHERD_TEST_HERDR']
        with tempfile.TemporaryDirectory(prefix='sshepherd-herdr-fixture-') as directory:
            root = Path(directory)
            for name in ['home', 'runtime', 'config', 'state', 'data', 'tmp', 'bin']:
                (root / name).mkdir(mode=0o700)
            (root / 'config/herdr').mkdir()
            (root / 'config/herdr/config.toml').write_text('onboarding = false\n')
            received = root / 'received'
            shell = root / 'capture-shell'
            shell.write_text(f'#!{sys.executable}\n' + '''import os, tty
from pathlib import Path
tty.setraw(0)
os.write(1, b'FIXTURE_READY')
with open(os.environ['FIXTURE_CAPTURE'], 'ab', buffering=0) as out:
    while True:
        data = os.read(0, 65536)
        if not data: break
        out.write(data)
''')
            shell.chmod(0o700)
            wrapper = root / 'bin/herdr'
            wrapper.write_text(f'#!{sys.executable}\nimport os, sys\nos.execv({binary!r}, [{binary!r}] + sys.argv[1:])\n')
            wrapper.chmod(0o700)
            env = {k: v for k, v in os.environ.items() if not k.startswith('HERDR_')}
            env.update(HOME=str(root / 'home'), XDG_RUNTIME_DIR=str(root / 'runtime'),
                       XDG_CONFIG_HOME=str(root / 'config'), XDG_STATE_HOME=str(root / 'state'),
                       XDG_DATA_HOME=str(root / 'data'), TMPDIR=str(root / 'tmp'),
                       SHELL=str(shell), FIXTURE_CAPTURE=str(received),
                       PATH=str(root / 'bin') + os.pathsep + env['PATH'])
            proc = subprocess.Popen([sys.executable, '-u', str(BRIDGE)], env=env,
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            image = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jC1sAAAAASUVORK5CYII=')
            try:
                proc.stdin.write(frame(2, struct.pack('>HH', 80, 24))); proc.stdin.flush()
                deadline = time.monotonic() + 20
                uploaded = False
                queried = False
                focused = False
                decoder = OutputFrames()
                rendered = bytearray()
                while time.monotonic() < deadline:
                    if select.select([proc.stdout], [], [], .05)[0]:
                        chunk = os.read(proc.stdout.fileno(), 65536)
                        if not chunk: self.fail('Herdr fixture exited: ' + proc.stderr.read().decode(errors='replace'))
                        for kind, body in decoder.push(chunk):
                            if kind == 1:
                                rendered.extend(body)
                            else:
                                response = json.loads(body)
                                self.assertEqual(response['error'], '')
                                if response['id'] == 'list':
                                    self.assertTrue(response['workspaces'])
                                    target = response['workspaces'][0]['workspace_id']
                                    proc.stdin.write(frame(6, json.dumps({'id': 'focus', 'action': 'workspace', 'workspace_id': target}).encode()))
                                    proc.stdin.flush()
                                elif response['id'] == 'focus':
                                    self.assertTrue(response['selected']); focused = True
                    if not queried and b'FIXTURE_READY' in rendered:
                        proc.stdin.write(frame(6, b'{"id":"list","action":"list"}'))
                        proc.stdin.flush(); queried = True
                    if not uploaded and focused:
                        proc.stdin.write(frame(3, struct.pack('>I', len(image)) + b'png') + frame(4, image) + frame(5, b''))
                        proc.stdin.flush(); uploaded = True
                    if received.exists() and b'herdr-clipboard-images-' in received.read_bytes():
                        path = received.read_text().replace('\x1b[200~', '').replace('\x1b[201~', '')
                        self.assertTrue(path.startswith(str(root / 'tmp/herdr-clipboard-images-')))
                        self.assertEqual(Path(path).read_bytes(), image)
                        return
                self.fail('Herdr did not route image to fixture pane; uploaded=' + str(uploaded) +
                          '; received=' + repr(received.read_bytes() if received.exists() else b'') +
                          '; output=' + repr(bytes(rendered[-1000:])))
            finally:
                proc.stdin.close()
                try: proc.wait(timeout=5)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait()
                for stream in (proc.stdout, proc.stderr): stream.close()
                # Explicit isolated environment/session only, never the user's server.
                subprocess.run([binary, '--session', 'default', 'server', 'stop'], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
