"""Runs remotely, in memory. stdin/stdout: [type:u8][length:u32 BE][body].
stdout type 1 is VT; type 2 is a bounded native-directory JSON response.
Only the Herdr *client* owns this PTY; disconnecting never kills the Herdr server.
"""
import errno
import fcntl
import os
import pty
import json
from pathlib import Path
import queue
import socket
import threading
import time
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
    if kind not in (1, 2, 3, 4, 5, 6) or (kind == 2 and length != 4) or (kind == 5 and length != 0) or (kind == 6 and length > 1024):
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


MAX_DIRECTORY = 2 * 1024 * 1024


def write_output(kind, body):
    view = memoryview(struct.pack('>BI', kind, len(body)) + body)
    while view:
        view = view[os.write(1, view):]


class ApiRejected(ValueError):
    pass


def herdr_request(method, params):
    # Match the default session launched below, not an inherited pane's socket.
    path = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'herdr/herdr.sock'
    deadline = time.monotonic() + 2
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(2)
        connection.connect(str(path))
        connection.sendall(json.dumps({'id': 'sshepherd', 'method': method, 'params': params}).encode() + b'\n')
        data = bytearray()
        while b'\n' not in data:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError()
            connection.settimeout(remaining)
            chunk = connection.recv(65536)
            if not chunk:
                raise ValueError('incomplete API response')
            data.extend(chunk)
            if len(data) > MAX_DIRECTORY:
                raise ValueError('oversized API response')
    response = json.loads(data.split(b'\n', 1)[0])
    if 'error' in response:
        raise ApiRejected('Herdr API rejected request')
    if not isinstance(response.get('result'), dict):
        raise ValueError('Invalid Herdr API response')
    return response['result']


def project_target(project):
    """Match nix-configs' Ctrl+K helper without passing input to a shell."""
    if project == 'Empty (~)':
        return str(Path.home()), '~'
    if (not isinstance(project, str) or not project or len(project.encode('utf-8')) > 256
            or any(ord(c) < 32 or ord(c) == 127 for c in project)
            or project.startswith('/') or any(p in ('', '.', '..') for p in project.split('/'))):
        raise ValueError('invalid project')
    root = (Path.home() / 'Documents').resolve(strict=True)
    target = (root / project).resolve(strict=True)
    if root not in target.parents or not target.is_dir():
        raise ValueError('project outside Documents')
    return str(target), project


def list_projects():
    root = Path.home() / 'Documents'
    projects = set()
    if root.is_dir():
        # .git entries at find -maxdepth 3; do not follow directory symlinks.
        for directory, dirs, files in os.walk(root):
            relative = Path(directory).relative_to(root)
            depth = len(relative.parts)
            if '.git' in dirs or '.git' in files:
                project = relative.as_posix()
                try:
                    project_target(project)
                    projects.add(project)
                except (OSError, ValueError):
                    pass
            if depth >= 2:
                dirs[:] = []
            else:
                dirs[:] = [d for d in dirs if d != '.git']
            if len(projects) > 512:
                raise ValueError('too many projects')
    return ['Empty (~)'] + sorted(projects)


def directory_request(body):
    request = json.loads(body)
    request_id = request.get('id')
    if not isinstance(request_id, str) or not 1 <= len(request_id) <= 64:
        raise ValueError('invalid request ID')
    reply = {'id': request_id, 'error': ''}
    focus_submitted = False
    try:
        action = request.get('action')
        if action == 'summary':
            agents = herdr_request('session.snapshot', {})['snapshot']['agents']
            if not isinstance(agents, list) or len(agents) > 4096 or any(not isinstance(agent, dict) for agent in agents):
                raise ValueError('invalid agents')
            counts = dict.fromkeys(('working', 'blocked', 'idle', 'done', 'unknown'), 0)
            for agent in agents:
                kind = agent.get('display_agent') or agent.get('agent')
                if not isinstance(kind, str) or not kind.strip():
                    continue
                status = agent.get('agent_status')
                counts[status if isinstance(status, str) and status in counts else 'unknown'] += 1
            reply['summary'] = counts
        elif action == 'list':
            snapshot = herdr_request('session.snapshot', {})['snapshot']
            for name, limit, fields in (
                ('workspaces', 512, ('workspace_id', 'label', 'agent_status', 'pane_count', 'tab_count')),
                ('agents', 4096, ('workspace_id', 'pane_id', 'tab_id', 'name', 'agent', 'display_agent',
                                  'title', 'terminal_title_stripped', 'agent_status')),
            ):
                rows = snapshot[name]
                if not isinstance(rows, list) or len(rows) > limit or any(not isinstance(row, dict) for row in rows):
                    raise ValueError('invalid directory')
                # Explicit metadata allowlist: no terminal buffers, credentials,
                # arbitrary token maps or agent session payloads reach the UI.
                reply[name] = [{key: (row[key][:512] if isinstance(row[key], str) else row[key])
                                for key in fields if key in row and isinstance(row[key], (str, int))}
                               for row in rows]
        elif action == 'projects':
            reply['projects'] = list_projects()
        elif action == 'create':
            cwd, label = project_target(request.get('project'))
            focus_submitted = True
            herdr_request('workspace.create', {'cwd': cwd, 'label': label, 'focus': True})
            reply['selected'] = True
        elif action in ('workspace', 'pane'):
            key = action + '_id'
            target = request.get(key)
            if not isinstance(target, str) or not 1 <= len(target) <= 128 or any(ord(c) < 32 for c in target):
                raise ValueError('invalid target')
            focus_submitted = True
            herdr_request(action + '.focus', {key: target})
            reply['selected'] = True
        else:
            raise ValueError('unsupported action')
    except (OSError, ValueError, KeyError, TypeError, RecursionError) as error:
        reply = {'id': request_id, 'error': 'Herdr workspace API unavailable or selection no longer exists. Refresh and retry.',
                 'uncertain': focus_submitted and not isinstance(error, ApiRejected)}
    payload = json.dumps(reply).encode()
    if len(payload) > MAX_DIRECTORY:
        payload = json.dumps({'id': request_id, 'error': 'Workspace list is too large.'}).encode()
    return payload


class DirectoryWorker:
    """One bounded API request at a time; a slow socket never blocks the PTY."""
    def __init__(self):
        self.reader, self.writer = socket.socketpair()
        self.result = queue.Queue(maxsize=1)
        self.busy = False

    def submit(self, body):
        if self.busy:
            request_id = json.loads(body).get('id', '')
            return json.dumps({'id': request_id, 'error': 'Workspace request already in progress.'}).encode()
        self.busy = True
        def work():
            try:
                payload = directory_request(body)
            except (ValueError, TypeError, AttributeError, RecursionError):
                payload = b'{"id":"","error":"Invalid workspace request."}'
            self.result.put(payload)
            try:
                self.writer.sendall(b'1')
            except OSError:
                pass
        threading.Thread(target=work, daemon=True).start()
        return None

    def receive(self):
        self.reader.recv(1)
        self.busy = False
        return self.result.get_nowait()

    def close(self):
        self.reader.close()
        self.writer.close()


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
    deferred_focus = None
    focus_deadline = None
    images = ImageUpload()
    directory = DirectoryWorker()
    os.set_blocking(master, False)
    selector = selectors.DefaultSelector()
    selector.register(0, selectors.EVENT_READ)
    selector.register(master, selectors.EVENT_READ)
    selector.register(directory.reader, selectors.EVENT_READ)
    try:
        while True:
            while deferred_focus is None:
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
                elif kind == 6:
                    request = json.loads(body)
                    if request.get('action') in ('workspace', 'pane', 'create') and pending:
                        # Do not let a separate API socket overtake earlier
                        # keyboard/composition bytes waiting for the PTY.
                        deferred_focus = body
                        focus_deadline = time.monotonic() + 2
                    else:
                        reply = directory.submit(body)
                        if reply is not None:
                            write_output(2, reply)
                else:
                    drop = images.frame(kind, body)
                    if drop:
                        pending.extend(drop)
                        if len(pending) > 1024 * 1024:
                            raise ValueError('PTY input backlog full')
            if deferred_focus is not None:
                if not pending:
                    reply = directory.submit(deferred_focus)
                    if reply is not None:
                        write_output(2, reply)
                    deferred_focus = None
                elif time.monotonic() >= focus_deadline:
                    request_id = json.loads(deferred_focus)['id']
                    write_output(2, json.dumps({'id': request_id, 'error': 'Terminal input is still pending; selection was not applied.'}).encode())
                    deferred_focus = None
            selector.modify(master, selectors.EVENT_READ | (selectors.EVENT_WRITE if pending else 0))
            for key, events in selector.select(.1 if deferred_focus is not None else None):
                if key.fd == 0:
                    chunk = os.read(0, 65536)
                    if not chunk:
                        return
                    buffer.extend(chunk)
                    if len(buffer) > 1024 * 1024:
                        raise ValueError('input backlog full')
                elif key.fileobj is directory.reader:
                    write_output(2, directory.receive())
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
                        # Frame VT separately so terminal escape sequences cannot
                        # impersonate native workspace responses.
                        write_output(1, output)
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
        directory.close()


if __name__ == '__main__':
    main()
