#!/usr/bin/env python3
"""Ephemeral stdio MCP transport for the synthetic Mac acceptance driver.

No credentials, default profile, service discovery, shell, or independent CLI
execution. The owning driver checks the real app-server tool-call thread before
forwarding a request to its existing anonymous-stdin CLI bridge. Configure only
on the acceptance app-server command line, never in user/project config files.
"""
import json
import socket
import sys


def main():
    endpoint = sys.argv[1]
    if len(sys.argv) != 2 or not endpoint.startswith('/tmp/aim-mcp-'):
        raise SystemExit(64)
    tool = {
        'name': 'codex_info',
        'description': 'Synthetic Mac acceptance only. Use your actual chatId and '
        'the reviewed info-codex JSON as input. Private association comes from '
        'your real SessionStart or explicit parent delegation. The QA driver '
        'binds chatId to the actual app-server MCP caller, and forwards input '
        'through anonymous stdin, with no business command-line arguments.',
        'inputSchema': {
            'type': 'object',
            'properties': {
                'chatId': {'type': 'string'},
                'input': {'type': 'object', 'additionalProperties': True},
            },
            'required': ['chatId', 'input'],
            'additionalProperties': False,
        },
    }
    for line in sys.stdin:
        request = json.loads(line)
        if 'id' not in request:
            continue
        method = request.get('method')
        if method == 'initialize':
            result = {
                'protocolVersion': request['params']['protocolVersion'],
                'capabilities': {'tools': {}},
                'serverInfo': {'name': 'synthetic-mac-info-qa', 'version': '1.0'},
            }
        elif method == 'tools/list':
            result = {'tools': [tool]}
        elif method == 'ping':
            result = {}
        elif method == 'tools/call':
            try:
                assert request['params']['name'] == 'codex_info'
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
                    channel.settimeout(60)
                    channel.connect(endpoint)
                    channel.sendall(json.dumps(request['params']['arguments']).encode() + b'\n')
                    with channel.makefile('rb') as stream:
                        value = json.loads(stream.readline(1024 * 1024))
                result = {'content': [{'type': 'text', 'text': json.dumps(value)}]}
            except Exception as error:
                result = {'content': [{'type': 'text', 'text': json.dumps({
                    'qaBridgeError': type(error).__name__,
                })}], 'isError': True}
        else:
            print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'error': {
                'code': -32601, 'message': 'Unsupported QA MCP method',
            }}), flush=True)
            continue
        print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)


if __name__ == '__main__':
    main()
