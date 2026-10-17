#!/usr/bin/env python3
"""Exercise the stock-client proxy against an isolated Herdr server and PTY."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import termios
import time
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('bridge', Path(__file__).with_name('herdr-phone-bridge.py'))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def test_frames_fragmentation_and_multiple_messages(self):
        parser = bridge.Frames()
        packets = bridge.frame(b'one') + bridge.frame(b'two')
        output = []
        for byte in packets:
            output.extend(parser.feed(bytes([byte])))
        self.assertEqual(output, [b'one', b'two'])
        for length in [0, bridge.LIMIT + 1]:
            with self.assertRaises(ValueError):
                list(bridge.Frames().feed(struct.pack('<I', length)))

    def test_controls_fragmentation_preserves_keys(self):
        import base64
        control = bridge.PREFIX + base64.b64encode(b'{"type":"focus"}') + b'\x07'
        parser = bridge.Controls()
        terminal, requests = bytearray(), []
        for byte in b'hello' + control + b'world':
            keys, values = parser.feed(bytes([byte]))
            terminal.extend(keys)
            requests.extend(values)
        self.assertEqual(terminal, b'helloworld')
        self.assertEqual(requests, [dict(type='focus')])
        keys, values = parser.feed(bridge.PREFIX + b'bad!' + b'\x07')
        self.assertEqual(keys, b'')
        self.assertEqual(values, [None])

    def test_requests_are_allowlisted_and_require_current_stable_target(self):
        catalog = dict(boot_id='boot', workspaces=[dict(workspace_id='w2')], panes=[dict(pane_id='w2:p1')])
        request = dict(type='focus', id='test', boot_id='boot', kind='pane', target='w2:p1')
        wire_id, packet = bridge.request_packet(request, catalog)
        self.assertEqual(wire_id, 'sshepherd-test')
        reader = bridge.Reader(packet[4:])
        self.assertEqual(reader.integer(), 15)
        self.assertEqual(reader.string(), 'boot')
        self.assertEqual(json.loads(reader.string()), dict(id=wire_id, method='pane.focus', params=dict(pane_id='w2:p1')))
        for change in [dict(boot_id='old'), dict(kind='server.stop'), dict(target='deleted'), dict(id=''), dict(type='exec')]:
            with self.assertRaises(ValueError):
                bridge.request_packet(dict(request, **change), catalog)


def exact(connection, count):
    result = bytearray()
    while len(result) < count:
        data = connection.recv(count - len(result))
        if not data:
            raise RuntimeError('connection closed')
        result.extend(data)
    return bytes(result)


class Endpoint:
    def __init__(self, path):
        self.connection = socket.socket(socket.AF_UNIX)
        self.connection.settimeout(5)
        self.connection.connect(str(path))
        self.catalog = None
        hello = dict(generation=1, cell_width_px=8, cell_height_px=16,
                     surface_size=dict(cols=80, rows=24), pixel_mouse=False, direct_graphics=False,
                     endpoint_keybindings=False, mouse_capture=False, snapshot_codecs=['shell.snapshot.v1'],
                     surface_codecs=['shell.surface.v1'], input_codecs=['shell.input.semantic.v1'], blob_codecs=['shell.blob.v1'])
        self.connection.sendall(bridge.frame(bridge.integer(20) + bridge.string('endpoint.hello.v1') + bridge.string(json.dumps(hello))))
        while self.catalog is None:
            self.receive()

    def receive(self):
        length = struct.unpack('<I', exact(self.connection, 4))[0]
        assert 0 < length <= bridge.LIMIT
        reader = bridge.Reader(exact(self.connection, length))
        tag = reader.integer()
        if tag == 20:
            kind, value = reader.string(), reader.string()
            if kind == 'shell.snapshot.v1':
                self.catalog = json.loads(value)
        if tag == 18:
            reader.string()
            request_id = reader.string()
            final = reader.take(1)[0]
            result = reader.take(reader.integer())
            if final:
                result = json.loads(result)
                assert 'error' not in result, result
                return request_id
        return None

    def request(self, method, params):
        value = json.dumps(dict(id='fixture', method=method, params=params))
        self.connection.sendall(bridge.frame(bridge.integer(15) + bridge.string(self.catalog['boot_id']) + bridge.string(value)))
        while self.receive() != 'fixture':
            pass
        while select.select([self.connection], [], [], .2)[0]:
            self.receive()

    def focus(self):
        return tuple(self.catalog.get(key) for key in ['focused_workspace_id', 'focused_tab_id', 'focused_pane_id'])


def integration(args):
    root = Path(args.scratch_dir).resolve()
    root.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root / 'config'),
               HERDR_CONFIG_PATH=str(root / 'config.toml'), HERDR_SOCKET_PATH=str(root / 'api.sock'))
    (root / 'config.toml').write_text('onboarding = false\n')
    log = (root / 'server.log').open('w')
    server = subprocess.Popen([args.herdr, 'server'], env=env, stdout=log, stderr=log, cwd=root)
    desktop, phone, master = None, None, None
    try:
        for _ in range(150):
            if (root / 'api-client.sock').exists():
                break
            if server.poll() is not None:
                raise RuntimeError('isolated server failed')
            time.sleep(.05)
        desktop = Endpoint(root / 'api-client.sock')
        desktop.request('workspace.create', dict(label='Desktop fixture', focus=True))
        desktop_target = desktop.focus()
        desktop.request('workspace.create', dict(label='Phone fixture', focus=True))
        phone_workspace = desktop.catalog['focused_workspace_id']
        desktop.request('workspace.focus', dict(workspace_id=desktop_target[0]))
        baseline = desktop.focus()
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 640, 384))
        phone = subprocess.Popen([sys.executable, str(Path(__file__).with_name('herdr-phone-bridge.py')),
                                  '--herdr', args.herdr, '--socket', str(root / 'api-client.sock'),
                                  '--runtime-dir', str(root / 'run')], stdin=slave, stdout=slave, stderr=slave,
                                 env=dict(env, TERM='xterm-256color'), cwd=root, start_new_session=True)
        os.close(slave)
        parser, catalog = bridge.Controls(maximum=4 * 1024 * 1024), None
        def respond(data):
            for query, reply in [(b'\x1b[6n', b'\x1b[1;1R'), (b'\x1b[?u', b'\x1b[?0u'),
                                 (b'\x1b[c', b'\x1b[?62;22c'), (b'\x1b[>c', b'\x1b[>1;0;0c'),
                                 (b'\x1b[14t', b'\x1b[4;384;640t'), (b'\x1b[16t', b'\x1b[6;16;8t')]:
                if query in data:
                    os.write(master, reply)
        def read_until(predicate):
            nonlocal catalog
            deadline = time.monotonic() + 15
            seen = []
            while time.monotonic() < deadline:
                if not select.select([master], [], [], .2)[0]:
                    continue
                data = os.read(master, 65536)
                if not data:
                    break
                respond(data)
                keys, messages = parser.feed(data)
                seen.append(keys)
                for message in messages:
                    if message.get('type') == 'catalog':
                        catalog = message['catalog']
                    if predicate(message):
                        return message
            raise RuntimeError('phone bridge did not respond: ' + repr(b''.join(seen)[-2000:]))
        read_until(lambda value: value.get('type') == 'catalog')
        for number, (kind, target) in enumerate([('workspace', phone_workspace), ('pane', baseline[2]), ('workspace', phone_workspace)]):
            request = dict(type='focus', id=str(number), boot_id=catalog['boot_id'], kind=kind, target=target)
            import base64
            os.write(master, bridge.PREFIX + base64.b64encode(json.dumps(request).encode()) + b'\x07')
            result = read_until(lambda value: value.get('type') == 'result' and value.get('id') == str(number))
            assert result.get('error') is None, result
            read_until(lambda value: value.get('type') == 'catalog' and value['catalog'].get('focused_' + ('workspace_id' if kind == 'workspace' else 'pane_id')) == target) if catalog.get('focused_' + ('workspace_id' if kind == 'workspace' else 'pane_id')) != target else None
            desktop.request('client_shell.surface.set', dict(active=True))
            assert desktop.focus() == baseline, (baseline, desktop.focus())
        def read_pane(pane_id):
            with socket.socket(socket.AF_UNIX) as api:
                api.settimeout(5)
                api.connect(str(root / 'api.sock'))
                api.sendall(json.dumps(dict(id='read', method='pane.read', params=dict(pane_id=pane_id, source='visible'))).encode() + b'\n')
                value = json.loads(api.makefile('rb').readline())
                assert 'error' not in value, value
                return value['result']['read']['text']
        marker = 'SSHEPHERD_BRIDGE_EXECUTED'
        settle = time.monotonic() + .5
        while time.monotonic() < settle:
            if select.select([master], [], [], .05)[0]:
                data = os.read(master, 65536)
                respond(data)
                parser.feed(data)
        for byte in b"printf 'SSHEPHERD_BRIDGE_%s\\n' EXECUTED\r":
            os.write(master, bytes([byte]))
            time.sleep(.005)
        deadline = time.monotonic() + 8
        while marker not in read_pane(phone_workspace + ':p1'):
            if time.monotonic() > deadline:
                raise RuntimeError('terminal input did not reach selected phone pane: ' + repr(read_pane(phone_workspace + ':p1')) + ' / desktop: ' + repr(read_pane(baseline[2])))
            if select.select([master], [], [], .1)[0]:
                data = os.read(master, 65536)
                respond(data)
                parser.feed(data)
        assert marker not in read_pane(baseline[2]), 'terminal input reached the wrong pane'
        desktop.request('client_shell.surface.set', dict(active=True))
        assert desktop.focus() == baseline
        print('PASS: real stock Herdr PTY bridge serves catalogs and focuses workspace/pane without changing desktop focus', baseline)
        print('PASS: terminal command executes in the selected phone pane, not the desktop-selected pane')
    finally:
        if phone is not None:
            # Stop the proxy session and its frontend, never the Herdr agent PTYs.
            phone.terminate()
            try:
                phone.wait(timeout=8)
            except subprocess.TimeoutExpired:
                phone.kill(); phone.wait()
        if master is not None:
            os.close(master)
        if desktop is not None:
            desktop.connection.close()
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill(); server.wait()
        log.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--herdr')
    parser.add_argument('--scratch-dir')
    args = parser.parse_args()
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(BridgeTests))
    if not result.wasSuccessful():
        sys.exit(1)
    if args.herdr and args.scratch_dir:
        integration(args)
