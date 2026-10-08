#!/usr/bin/env python3
"""Keep stock Herdr rendering/input; expose its own endpoint catalog to SSHepherd.

Only workspace/pane focus is injected on the stock client's existing connection.
No public API socket, agent restart, arbitrary command, or forwarding is exposed.
"""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import tty
import time

PREFIX = b'\x1b]777;sshepherd;'
LIMIT = 16 * 1024 * 1024


def integer(n):
    if n < 251:
        return bytes([n])
    for tag, fmt, maximum in [(251, '<H', 65535), (252, '<I', 4294967295), (253, '<Q', 18446744073709551615)]:
        if n <= maximum:
            return bytes([tag]) + struct.pack(fmt, n)
    raise ValueError('integer too large')


def string(value):
    raw = value.encode('utf-8')
    return integer(len(raw)) + raw


def frame(payload):
    if not 0 < len(payload) <= LIMIT:
        raise ValueError('invalid frame size')
    return struct.pack('<I', len(payload)) + payload


class Reader:
    def __init__(self, data):
        self.data, self.offset = data, 0

    def take(self, count):
        if count < 0 or count > len(self.data) - self.offset:
            raise ValueError('truncated message')
        result = self.data[self.offset:self.offset + count]
        self.offset += count
        return result

    def integer(self):
        tag = self.take(1)[0]
        if tag < 251:
            return tag
        sizes = {251: 2, 252: 4, 253: 8}
        if tag not in sizes:
            raise ValueError('invalid integer tag')
        return int.from_bytes(self.take(sizes[tag]), 'little')

    def string(self):
        return self.take(self.integer()).decode('utf-8')


class Frames:
    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        self.buffer.extend(data)
        while len(self.buffer) >= 4:
            length = struct.unpack('<I', self.buffer[:4])[0]
            if not 0 < length <= LIMIT:
                raise ValueError('invalid frame length')
            if len(self.buffer) < length + 4:
                break
            payload = bytes(self.buffer[4:4 + length])
            del self.buffer[:4 + length]
            yield payload


class Controls:
    def __init__(self, maximum=8192):
        self.buffer = bytearray()
        self.maximum = maximum

    def feed(self, data):
        self.buffer.extend(data)
        output, requests = bytearray(), []
        while self.buffer:
            start = self.buffer.find(PREFIX)
            if start < 0:
                keep = next((n for n in range(min(len(PREFIX) - 1, len(self.buffer)), 0, -1)
                             if self.buffer.endswith(PREFIX[:n])), 0)
                output.extend(self.buffer[:len(self.buffer) - keep])
                del self.buffer[:len(self.buffer) - keep]
                break
            output.extend(self.buffer[:start])
            del self.buffer[:start]
            end = self.buffer.find(b'\x07', len(PREFIX))
            if end < 0:
                if len(self.buffer) > self.maximum:
                    raise ValueError('oversized control')
                break
            if end > self.maximum:
                raise ValueError('oversized control')
            encoded = bytes(self.buffer[len(PREFIX):end])
            del self.buffer[:end + 1]
            try:
                requests.append(json.loads(base64.b64decode(encoded, validate=True)))
            except (ValueError, UnicodeError):
                # Never forward malformed private controls to an agent's terminal.
                requests.append(None)
        return bytes(output), requests


def write_all(fd, data):
    while data:
        count = os.write(fd, data)
        if count <= 0:
            raise OSError('closed output')
        data = data[count:]


def emit(value):
    raw = json.dumps(value, separators=(',', ':')).encode()
    write_all(1, PREFIX + base64.b64encode(raw) + b'\x07')


def request_packet(request, catalog):
    if not isinstance(request, dict) or request.get('type') != 'focus':
        raise ValueError('invalid request')
    request_id = request.get('id')
    if not isinstance(request_id, str) or not 1 <= len(request_id) <= 80:
        raise ValueError('invalid request ID')
    if not catalog or request.get('boot_id') != catalog.get('boot_id'):
        raise ValueError('catalog expired; reconnect')
    kind, target = request.get('kind'), request.get('target')
    if kind == 'workspace':
        key, resources, method = 'workspace_id', 'workspaces', 'workspace.focus'
    elif kind == 'pane':
        key, resources, method = 'pane_id', 'panes', 'pane.focus'
    else:
        raise ValueError('unsupported selection')
    if not isinstance(target, str) or not any(item.get(key) == target for item in catalog.get(resources, [])):
        raise ValueError('selection no longer exists')
    wire_id = 'sshepherd-' + request_id
    body = json.dumps(dict(id=wire_id, method=method, params={key: target}), separators=(',', ':'))
    return wire_id, frame(integer(15) + string(catalog['boot_id']) + string(body))


def run(args):
    if not os.isatty(0):
        raise RuntimeError('a terminal is required')
    runtime = Path(args.runtime_dir).expanduser()
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    if runtime.stat().st_uid != os.getuid() or runtime.stat().st_mode & 0o077:
        raise RuntimeError('runtime directory must be private and owned by this user')
    def stop(*_):
        raise SystemExit(0)
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, stop)
    saved = termios.tcgetattr(0)
    child, listener, frontend, backend, master = None, None, None, None, None
    with tempfile.TemporaryDirectory(prefix='b-', dir=runtime) as temporary:
        proxy = str(Path(temporary) / 'api-client.sock')
        if len(os.fsencode(proxy)) > 103:
            raise RuntimeError('runtime socket path is too long')
        try:
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(proxy)
            os.chmod(proxy, 0o600)
            listener.listen(1)
            listener.settimeout(15)
            master, slave = os.openpty()
            def resize(*_):
                geometry = fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8)
                fcntl.ioctl(master, termios.TIOCSWINSZ, geometry)
                if child is not None:
                    child.send_signal(signal.SIGWINCH)
            resize()
            signal.signal(signal.SIGWINCH, resize)
            env = dict(os.environ, HERDR_SOCKET_PATH=str(Path(temporary) / 'api.sock'))
            for key in ('HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_TAB_ID', 'HERDR_WORKSPACE_ID'):
                env.pop(key, None)
            # "client" never starts a server. The proxy is its sole endpoint socket.
            tty.setraw(0)
            child = subprocess.Popen([args.herdr, 'client'], stdin=slave, stdout=slave, stderr=slave,
                                     env=env, start_new_session=True)
            os.close(slave)
            # Stock Herdr can query the host terminal before opening its endpoint.
            # Relay those queries/replies while waiting; blocking accept deadlocks it.
            deadline = time.monotonic() + 15
            while frontend is None:
                if time.monotonic() > deadline or child.poll() is not None:
                    raise RuntimeError('Herdr frontend did not open its endpoint')
                ready, _, _ = select.select([0, master, listener], [], [], .2)
                if master in ready:
                    write_all(1, os.read(master, 65536))
                if 0 in ready:
                    data = os.read(0, 65536)
                    if not data:
                        return
                    write_all(master, data)
                if listener in ready:
                    frontend, _ = listener.accept()
            listener.close()
            backend = socket.socket(socket.AF_UNIX)
            backend.settimeout(5)
            backend.connect(args.socket)
            frontend.setblocking(False)
            backend.setblocking(False)
            os.set_blocking(master, False)
            tty.setraw(0)
            upstream, downstream, controls = Frames(), Frames(), Controls()
            to_frontend, to_backend, to_terminal = bytearray(), bytearray(), bytearray()
            catalog, pending, response = None, None, bytearray()
            last_input = time.monotonic()
            while child.poll() is None:
                writable = ([frontend] if to_frontend else []) + ([backend] if to_backend else []) + ([master] if to_terminal else [])
                ready, writes, _ = select.select([0, master, frontend, backend], writable, [], .05 if controls.buffer else 1)
                # A lone Escape key shares the OSC prefix; do not retain it forever.
                if controls.buffer and len(controls.buffer) < len(PREFIX) and time.monotonic() - last_input >= .15:
                    to_terminal.extend(controls.buffer)
                    controls.buffer.clear()
                if master in writes:
                    count = os.write(master, to_terminal)
                    del to_terminal[:count]
                for connection, queue in [(frontend, to_frontend), (backend, to_backend)]:
                    if connection in writes:
                        count = connection.send(queue)
                        del queue[:count]
                if 0 in ready:
                    data = os.read(0, 65536)
                    if not data:
                        break
                    last_input = time.monotonic()
                    keys, requests = controls.feed(data)
                    if keys:
                        to_terminal.extend(keys)
                    for request in requests:
                        try:
                            if pending is not None:
                                raise ValueError('another selection is still pending')
                            wire_id, packet = request_packet(request, catalog)
                            to_backend.extend(packet)
                            pending, response = wire_id, bytearray()
                        except ValueError as error:
                            emit(dict(type='result', id=request.get('id') if isinstance(request, dict) else None,
                                      error=str(error)))
                if master in ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    write_all(1, data)
                if frontend in ready:
                    data = frontend.recv(65536)
                    if not data:
                        break
                    for payload in upstream.feed(data):
                        to_backend.extend(frame(payload))
                if backend in ready:
                    data = backend.recv(65536)
                    if not data:
                        break
                    for payload in downstream.feed(data):
                        reader = Reader(payload)
                        tag = reader.integer()
                        if tag == 20:
                            kind, value = reader.string(), reader.string()
                            if kind == 'shell.snapshot.v1':
                                catalog = json.loads(value)
                                browser_catalog = {key: catalog[key] for key in (
                                    'boot_id', 'revision', 'focused_workspace_id', 'focused_tab_id',
                                    'focused_pane_id', 'workspaces', 'agents', 'panes') if key in catalog}
                                emit(dict(type='catalog', catalog=browser_catalog))
                        if tag == 18:
                            boot_id, request_id = reader.string(), reader.string()
                            final = reader.take(1)[0]
                            chunk = reader.take(reader.integer())
                            if request_id.startswith('sshepherd-'):
                                if request_id == pending:
                                    response.extend(chunk)
                                    if len(response) > LIMIT:
                                        raise ValueError('oversized response')
                                    if final:
                                        result = json.loads(response)
                                        emit(dict(type='result', id=request_id[len('sshepherd-'):],
                                                  error=result.get('error', {}).get('message')))
                                        pending = None
                                continue
                        to_frontend.extend(frame(payload))
                if max(len(to_frontend), len(to_backend), len(to_terminal)) > 2 * LIMIT:
                    raise ValueError('proxy output queue exceeded its limit')
        finally:
            try:
                termios.tcsetattr(0, termios.TCSANOW, saved)
            except termios.error:
                pass  # The SSH PTY may already have hung up; still clean up the frontend.
            for connection in [listener, frontend, backend]:
                if connection is not None:
                    connection.close()
            if child is not None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            if master is not None:
                os.close(master)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--herdr', required=True)
    parser.add_argument('--socket', required=True)
    parser.add_argument('--runtime-dir', required=True)
    try:
        run(parser.parse_args())
    except (OSError, ValueError, RuntimeError) as error:
        print('SSHepherd bridge:', error, file=sys.stderr)
        sys.exit(1)
