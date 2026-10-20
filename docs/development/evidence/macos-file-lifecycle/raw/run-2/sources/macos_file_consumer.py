"""Consume only synthetic managed attachments through real loopback HTTP PUT."""
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import subprocess
import threading
import uuid


class LocalFileConsumer:
    def __init__(self, output):
        self.output = output
        self.accepted = []
        self.attempts = []
        self.token = uuid.uuid4().hex
        self.curl = Path('/usr/bin/curl')
        self.identity = {
            'path': str(self.curl),
            'sha256': hashlib.sha256(self.curl.read_bytes()).hexdigest(),
            'version': subprocess.check_output(
                [str(self.curl), '--version'], text=True).splitlines()[0],
        }
        consumer = self

        class Receiver(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_PUT(self):
                self.connection.settimeout(5)
                try:
                    size = int(self.headers.get('Content-Length', '-1'))
                    if (not self.path.startswith('/' + consumer.token + '/')
                            or not 0 <= size <= 1024 * 1024
                            or self.headers.get('Transfer-Encoding')):
                        self.send_error(400)
                        return
                    body = self.rfile.read(size)
                    if len(body) != size:
                        self.send_error(400)
                        return
                    result = {'byteLength': size,
                              'sha256': hashlib.sha256(body).hexdigest()}
                    # Bytes are retained only in this process for exact comparison.
                    consumer.accepted.append((self.path, body))
                    response = json.dumps(result).encode()
                    self.send_response(201)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(response)))
                    self.end_headers()
                    self.wfile.write(response)
                except (OSError, ValueError):
                    self.close_connection = True

        self.server = HTTPServer(('127.0.0.1', 0), Receiver)
        self.thread = threading.Thread(
            target=lambda: self.server.serve_forever(poll_interval=.1), daemon=True)
        self.thread.start()

    def _upload(self, path, label):
        url = f'http://127.0.0.1:{self.server.server_port}/{self.token}/{label}'
        # Disable user curl configuration and proxy inheritance. No shell, redirect,
        # external destination, credential, or private source file is involved.
        command = [str(self.curl), '-q', '--noproxy', '*', '--proxy', '',
                   '--connect-timeout', '3', '--max-time', '8', '--fail',
                   '--silent', '--show-error', '--upload-file', str(path), url]
        result = subprocess.run(command, capture_output=True, text=True, timeout=12)
        self.attempts.append({'label': label, 'command': command,
                             'exitCode': result.returncode,
                             'stdout': result.stdout, 'stderr': result.stderr})
        return result

    def consume(self, path, original, label):
        count = len(self.accepted)
        result = self._upload(path, label)
        assert result.returncode == 0, (label, result.returncode, result.stderr)
        assert len(self.accepted) == count + 1
        endpoint, received = self.accepted[-1]
        assert endpoint.endswith('/' + label) and received == original
        receipt = json.loads(result.stdout)
        assert receipt == {'byteLength': len(original),
                           'sha256': hashlib.sha256(original).hexdigest()}
        return {'consumer': 'system-curl-to-loopback-http',
                'httpSuccess': True, 'receiverBytesExactlyMatched': True,
                **receipt}

    def verify_released(self, path, label):
        assert not path.exists()
        count = len(self.accepted)
        result = self._upload(path, label + '-released')
        assert result.returncode == 26, (label, result.returncode, result.stderr)
        assert len(self.accepted) == count
        return {'releasedUploadExitCode': result.returncode,
                'receiverAcceptedNoNewFile': True}

    def close(self):
        self.server.shutdown()
        self.thread.join(timeout=5)
        self.server.server_close()
        assert not self.thread.is_alive()
        result = {'curl': self.identity, 'attempts': self.attempts,
                  'acceptedUploads': len(self.accepted),
                  'accepted': [{'endpoint': endpoint, 'byteLength': len(body),
                                'sha256': hashlib.sha256(body).hexdigest()}
                               for endpoint, body in self.accepted],
                  'receiverClosed': True,
                  'scope': 'Synthetic local HTTP upload; no external website or remote client.'}
        (self.output / 'file-consumer.json').write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        return {'acceptedUploads': len(self.accepted),
                'uploadAttempts': len(self.attempts), 'receiverClosed': True}
