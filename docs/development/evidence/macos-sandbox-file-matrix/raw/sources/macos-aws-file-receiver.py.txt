#!/usr/bin/env python3
"""Loopback S3 fixture for actual sandbox file read/write checks; synthetic only."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location('aws_fixture', Path(__file__).with_name('macos-aws-receiver.py'))
aws_fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aws_fixture)
PAYLOAD = ('Mac sandbox synthetic file fixture\n中文 空格\n' * 41).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    root.chmod(0o700)
    facts = {'valid': 0, 'invalid': 0, 'requests': [], 'payloadBytes': len(PAYLOAD),
             'payloadSha256': hashlib.sha256(PAYLOAD).hexdigest()}
    (root / 'expected.bin').write_bytes(PAYLOAD)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            payload_hash = self.headers.get('x-amz-content-sha256')
            accepted = (self.path == '/fixture-bucket/fixture-object' and
                        payload_hash in ('UNSIGNED-PAYLOAD', hashlib.sha256(b'').hexdigest()) and
                        aws_fixture.authenticates(self, b'', services=('s3',), payload_hash=payload_hash))
            facts['valid' if accepted else 'invalid'] += 1
            facts['requests'].append({'method': 'GET', 'accepted': accepted})
            (root / 'receiver-result.json').write_text(json.dumps(facts, indent=2) + '\n')
            data = PAYLOAD if accepted else b'<Error><Code>AccessDenied</Code><Message>Synthetic signature rejected</Message></Error>'
            self.send_response(200 if accepted else 403)
            self.send_header('Content-Type', 'application/octet-stream' if accepted else 'application/xml')
            self.send_header('Content-Length', str(len(data)))
            if accepted:
                self.send_header('ETag', '"synthetic"')
                self.send_header('x-amz-checksum-sha256', base64.b64encode(hashlib.sha256(data).digest()).decode())
                self.send_header('x-amz-checksum-type', 'FULL_OBJECT')
            self.end_headers()
            self.wfile.write(data)

    with HTTPServer(('127.0.0.1', 0), Handler) as server:
        (root / 'fixture.json').write_text(json.dumps({'port': server.server_port}) + '\n')
        print('S3_FIXTURE_READY', server.server_port, flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
