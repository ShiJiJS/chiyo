#!/usr/bin/env python3
"""Loopback-only synthetic SigV4 receiver; never records authorization headers."""
import argparse
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import re
from urllib.parse import parse_qsl, quote, urlsplit

ACCESS = 'TEST_ACCESS_ONLY'
SECRET = 'SYNTHETIC_NOT_A_REAL_SECRET'


def authenticates(handler, body):
    try:
        scheme, raw = handler.headers['Authorization'].split(' ', 1)
        values = dict(part.strip().split('=', 1) for part in raw.split(','))
        credential = values['Credential'].split('/')
        assert scheme == 'AWS4-HMAC-SHA256' and len(credential) == 5
        assert credential[0] == ACCESS and credential[2] == 'us-east-1'
        assert credential[3] in ('ssm', 'sts') and credential[4] == 'aws4_request'
        signed = values['SignedHeaders']
        names = signed.split(';')
        assert sorted(names) == names and 'host' in names and 'x-amz-date' in names
        headers = ''.join(name + ':' + re.sub(r'\s+', ' ', handler.headers[name].strip()) + '\n' for name in names)
        timestamp = handler.headers['x-amz-date']
        assert timestamp[:8] == credential[1]
        url = urlsplit(handler.path)
        query = '&'.join(sorted(quote(k, safe='-_.~') + '=' + quote(v, safe='-_.~') for k, v in parse_qsl(url.query, keep_blank_values=True)))
        canonical = '\n'.join([handler.command, url.path or '/', query, headers, signed, hashlib.sha256(body).hexdigest()])
        key = ('AWS4' + SECRET).encode()
        for value in credential[1:]:
            key = hmac.new(key, value.encode(), hashlib.sha256).digest()
        signing = '\n'.join([scheme, timestamp, '/'.join(credential[1:]), hashlib.sha256(canonical.encode()).hexdigest()])
        expected = hmac.new(key, signing.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected, values['Signature'])
    except (AssertionError, KeyError, TypeError, ValueError, AttributeError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    facts = {'valid': 0, 'invalid': 0, 'actions': []}
    parameters = {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            accepted = authenticates(self, body)
            facts['valid' if accepted else 'invalid'] += 1
            action = self.headers.get('x-amz-target', '').split('.')[-1]
            facts['actions'].append({'action': action or 'GetCallerIdentity', 'authenticated': accepted})
            if not accepted:
                status, kind = 403, 'application/x-amz-json-1.1'
                data = json.dumps({'__type': 'UnrecognizedClientException', 'message': 'Synthetic signature rejected'}).encode()
            elif action == 'PutParameter':
                value = json.loads(body)
                parameters[value['Name']] = value['Value']
                status, kind = 200, 'application/x-amz-json-1.1'
                data = b'{"Version":1,"Tier":"Standard"}'
            elif action == 'GetParameter':
                value = json.loads(body)
                status, kind = 200, 'application/x-amz-json-1.1'
                data = json.dumps({'Parameter': {'Name': value['Name'], 'Type': 'String', 'Value': parameters[value['Name']], 'Version': 1}}).encode()
            else:
                status, kind = 200, 'text/xml'
                data = b'<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><GetCallerIdentityResult><Arn>arn:aws:iam::000000000000:user/fixture</Arn><UserId>LOCALFIXTURE</UserId><Account>000000000000</Account></GetCallerIdentityResult><ResponseMetadata><RequestId>synthetic-request</RequestId></ResponseMetadata></GetCallerIdentityResponse>'
            (root / 'receiver-result.json').write_text(json.dumps(facts, indent=2) + '\n')
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    with HTTPServer(('127.0.0.1', 0), Handler) as server:
        (root / 'fixture.json').write_text(json.dumps({'port': server.server_port}) + '\n')
        server.serve_forever()


if __name__ == '__main__':
    main()
