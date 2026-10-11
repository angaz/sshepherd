import importlib.util
from contextlib import ExitStack
from types import SimpleNamespace
import json
import socket
import threading
from unittest.mock import patch
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


class OutputFrames:
    def __init__(self):
        self.buffer = bytearray()
    def push(self, chunk):
        self.buffer.extend(chunk)
        records = []
        while len(self.buffer) >= 5:
            kind, length = struct.unpack('>BI', self.buffer[:5])
            if kind not in (1, 2) or length > bridge.MAX_DIRECTORY:
                raise ValueError('invalid output frame')
            if len(self.buffer) < 5 + length: break
            records.append((kind, bytes(self.buffer[5:5 + length])))
            del self.buffer[:5 + length]
        return records


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

    def test_directory_frames_are_bounded(self):
        payload = b'{"id":"test","action":"list"}'
        self.assertEqual(bridge.pop_frame(bytearray(frame(6, payload))), (6, payload))
        with self.assertRaises(ValueError): bridge.pop_frame(bytearray(frame(6, b'x' * 1025)))

    def test_directory_filters_sensitive_payloads_and_only_allows_focus(self):
        state = {'workspaces': [{'workspace_id': 'w1', 'label': 'Project', 'tokens': {'secret': 'hidden'}}],
                 'agents': [{'workspace_id': 'w1', 'pane_id': 'w1:p1', 'agent': 'pi', 'title': 'Task',
                             'terminal_content': 'do not forward', 'agent_session': {'secret': 'hidden'}}]}
        with patch.object(bridge, 'herdr_request', return_value={'snapshot': state}) as rpc:
            response = json.loads(bridge.directory_request(b'{"id":"r1","action":"list"}'))
            rpc.assert_called_once_with('session.snapshot', {})
        self.assertEqual(response['workspaces'], [{'workspace_id': 'w1', 'label': 'Project'}])
        self.assertEqual(response['agents'][0]['title'], 'Task')
        self.assertNotIn('secret', json.dumps(response))
        self.assertNotIn('terminal_content', json.dumps(response))
        for action, target in [('workspace', 'w1'), ('pane', 'w1:p2')]:
            with patch.object(bridge, 'herdr_request', return_value={}) as rpc:
                request = json.dumps({'id': 'r2', 'action': action, action + '_id': target}).encode()
                self.assertTrue(json.loads(bridge.directory_request(request))['selected'])
                rpc.assert_called_once_with(action + '.focus', {action + '_id': target})
        with patch.object(bridge, 'herdr_request') as rpc:
            response = json.loads(bridge.directory_request(b'{"id":"bad","action":"pane.close"}'))
            self.assertTrue(response['error']); rpc.assert_not_called()

    def test_projects_match_ctrl_k_discovery_and_create_without_shell(self):
        with tempfile.TemporaryDirectory() as home, patch.object(bridge.Path, 'home', return_value=Path(home)):
            root = Path(home) / 'Documents'
            (root / 'alpha/.git').mkdir(parents=True)
            (root / 'group/worktree').mkdir(parents=True)
            (root / 'group/worktree/.git').write_text('gitdir: elsewhere')
            (root / 'too/deep/repo/.git').mkdir(parents=True)
            (root / 'escape').symlink_to(Path(home), target_is_directory=True)
            (root / 'bad\nname/.git').mkdir(parents=True)
            response = json.loads(bridge.directory_request(b'{"id":"p","action":"projects"}'))
            self.assertEqual(response['projects'], ['Empty (~)', 'alpha', 'group/worktree'])
            for project, cwd, label in [('alpha', root / 'alpha', 'alpha'), ('Empty (~)', Path(home), '~')]:
                with patch.object(bridge, 'herdr_request', return_value={}) as rpc:
                    body = json.dumps({'id': 'c', 'action': 'create', 'project': project}).encode()
                    self.assertTrue(json.loads(bridge.directory_request(body))['selected'])
                    rpc.assert_called_once_with('workspace.create', {'cwd': str(cwd), 'label': label, 'focus': True})
            for project in ('../', '/tmp', 'alpha/../alpha', 'escape', '', 'alpha\n', None):
                with patch.object(bridge, 'herdr_request') as rpc:
                    response = json.loads(bridge.directory_request(json.dumps({'id': 'c', 'action': 'create', 'project': project}).encode()))
                    self.assertTrue(response['error']); self.assertFalse(response['uncertain']); rpc.assert_not_called()
            with patch.object(bridge, 'herdr_request', side_effect=TimeoutError()):
                response = json.loads(bridge.directory_request(b'{"id":"c","action":"create","project":"alpha"}'))
                self.assertTrue(response['uncertain'])

    def test_summary_counts_only_recognized_agents_without_forwarding_metadata(self):
        agents = [{'agent': 'pi', 'agent_status': status, 'title': 'private', 'tokens': 'secret'}
                  for status in ('working', 'idle', 'idle', 'blocked', 'done', 'future')]
        agents += [{'agent': None, 'agent_status': 'idle'}, {'agent': '', 'agent_status': 'working'},
                   {'display_agent': 'claude', 'agent': None, 'agent_status': None}]
        with patch.object(bridge, 'herdr_request', return_value={'snapshot': {'agents': agents}}) as rpc:
            response = json.loads(bridge.directory_request(b'{"id":"s1","action":"summary"}'))
            rpc.assert_called_once_with('session.snapshot', {})
        self.assertEqual(response, {'id': 's1', 'error': '', 'summary': {
            'working': 1, 'blocked': 1, 'idle': 2, 'done': 1, 'unknown': 2}})
        for invalid in ({}, [None], [{}] * 4097):
            with patch.object(bridge, 'herdr_request', return_value={'snapshot': {'agents': invalid}}):
                response = json.loads(bridge.directory_request(b'{"id":"s2","action":"summary"}'))
                self.assertTrue(response['error']); self.assertNotIn('summary', response)

    def test_focus_waits_for_all_preceding_partial_pty_writes(self):
        payload = b'queued composition'
        initial = frame(2, struct.pack('>HH', 80, 24)) + frame(1, payload) + frame(6, b'{"id":"focus","action":"workspace","workspace_id":"w2"}')
        reads = iter((initial, b''))
        written = bytearray()
        outputs = bytearray()
        class Selector:
            def register(self, *args): pass
            def modify(self, *args): pass
            def close(self): pass
            def select(self, timeout=None):
                fd = 9 if len(written) < len(payload) else 0
                return [(SimpleNamespace(fd=fd, fileobj=fd), bridge.selectors.EVENT_WRITE if fd else bridge.selectors.EVENT_READ)]
        def write(fd, data):
            if fd == 9:
                count = min(2, len(data)); written.extend(data[:count]); return count
            outputs.extend(data); return len(data)
        def submit(body):
            self.assertEqual(bytes(written), payload)
            return b'{"id":"focus","selected":true,"error":""}'
        with ExitStack() as stack:
            worker = stack.enter_context(patch.object(bridge, 'DirectoryWorker')).return_value
            worker.submit.side_effect = submit
            stack.enter_context(patch.object(bridge, 'ImageUpload'))
            stack.enter_context(patch.object(bridge.pty, 'fork', return_value=(12345, 9)))
            stack.enter_context(patch.object(bridge.os, 'read', side_effect=lambda fd, n: next(reads)))
            stack.enter_context(patch.object(bridge.os, 'write', side_effect=write))
            for name in ('set_blocking', 'close', 'kill', 'waitpid'):
                stack.enter_context(patch.object(bridge.os, name))
            stack.enter_context(patch.object(bridge.selectors, 'DefaultSelector', return_value=Selector()))
            bridge.main()
            worker.submit.assert_called_once()
        replies = OutputFrames().push(outputs)
        self.assertTrue(json.loads(replies[0][1])['selected'])

    def test_focus_timeout_is_distinguished_from_explicit_rejection(self):
        body = b'{"id":"focus","action":"workspace","workspace_id":"w2"}'
        with patch.object(bridge, 'herdr_request', side_effect=TimeoutError()):
            response = json.loads(bridge.directory_request(body))
            self.assertTrue(response['uncertain']); self.assertTrue(response['error'])
        with patch.object(bridge, 'herdr_request', side_effect=bridge.ApiRejected()):
            response = json.loads(bridge.directory_request(body))
            self.assertFalse(response['uncertain']); self.assertTrue(response['error'])

    def test_directory_errors_do_not_escape_into_terminal_and_worker_is_bounded(self):
        worker = bridge.DirectoryWorker()
        release = threading.Event()
        entered = threading.Event()
        def slow(body):
            entered.set(); release.wait(3)
            return b'{"id":"r1","error":""}'
        try:
            with patch.object(bridge, 'directory_request', side_effect=slow):
                self.assertIsNone(worker.submit(b'{"id":"r1","action":"list"}'))
                self.assertTrue(entered.wait(1))
                busy = json.loads(worker.submit(b'{"id":"r2","action":"list"}'))
                self.assertEqual(busy['id'], 'r2'); self.assertTrue(busy['error'])
                release.set()
                self.assertTrue(select.select([worker.reader], [], [], 2)[0])
                self.assertEqual(json.loads(worker.receive())['id'], 'r1')
                self.assertFalse(worker.busy)
        finally:
            release.set(); worker.close()
        with patch.object(bridge, 'herdr_request', side_effect=TimeoutError()):
            self.assertTrue(json.loads(bridge.directory_request(b'{"id":"r3","action":"list"}'))['error'])

    def test_socket_api_fragmentation_and_error(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / 'herdr'; folder.mkdir()
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(folder / 'herdr.sock')); server.listen(1)
            def serve():
                connection, _ = server.accept()
                with connection:
                    request = bytearray()
                    while b'\n' not in request: request.extend(connection.recv(1000))
                    self.assertEqual(json.loads(request)['method'], 'session.snapshot')
                    connection.sendall(b'{"result":')
                    connection.sendall(b'{"snapshot":{}}}\n')
            thread = threading.Thread(target=serve); thread.start()
            try:
                with patch.dict(os.environ, {'XDG_CONFIG_HOME': directory, 'HERDR_SOCKET_PATH': '/not/the/default'}):
                    self.assertEqual(bridge.herdr_request('session.snapshot', {}), {'snapshot': {}})
            finally:
                thread.join(3); server.close()

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
            decoder = OutputFrames()

            def expect(value):
                deadline = time.monotonic() + 5
                while value not in output:
                    if time.monotonic() >= deadline:
                        self.fail(f'timed out waiting for {value!r}: {output!r}')
                    if select.select([proc.stdout], [], [], .1)[0]:
                        chunk = os.read(proc.stdout.fileno(), 65536)
                        if not chunk:
                            self.fail(f'bridge exited: {proc.stderr.read()!r}')
                        for kind, body in decoder.push(chunk):
                            self.assertEqual(kind, 1)
                            output.extend(body)
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
