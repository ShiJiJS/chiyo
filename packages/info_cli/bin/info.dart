import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// JSON-lines commands never carry or print session/grant credentials.
Future<void> main(List<String> args) async {
  var port = 47125;
  if (args.isNotEmpty) {
    if (args.length != 2 ||
        args.first != '--port' ||
        int.tryParse(args.last) == null ||
        int.parse(args.last) < 1 ||
        int.parse(args.last) > 65535) {
      stdout.writeln(jsonEncode({'status': 'invalid_request'}));
      exitCode = 64;
      return;
    }
    port = int.parse(args.last);
  }
  final client = _AgentClient(port);
  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      Map<String, dynamic> output;
      try {
        if (line.length > 16384) throw const FormatException();
        final command = jsonDecode(line);
        if (command is! Map<String, dynamic>) throw const FormatException();
        output = await client.execute(command);
      } on Object {
        output = {'status': 'invalid_request'};
      }
      stdout.writeln(jsonEncode(output));
    }
  } on Object {
    stdout.writeln(jsonEncode({'status': 'invalid_request'}));
  } finally {
    client.close();
  }
}

class _AgentClient {
  _AgentClient(this.port);
  final int port;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  String? _session;
  final _tokens = <String, String>{};
  void close() {
    _tokens.clear();
    _session = null;
    _http.close(force: true);
  }

  Future<Map<String, dynamic>> execute(Map<String, dynamic> input) async {
    final command = input['command'];
    switch (command) {
      case 'catalog':
        return _call('/catalog', {});
      case 'session':
        if (_session != null) return {'status': 'invalid_request'};
        final result = await _call('/session', {
          'chatLabel': input['chatLabel'],
        });
        final secret = result.remove('sessionSecret');
        if (result['status'] == 'ok' && secret is String) _session = secret;
        return result;
      case 'request':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/request', {
          'sessionSecret': _session,
          'purpose': input['purpose'],
          'fields': input['fields'],
        });
      case 'status':
      case 'claim':
        if (_session == null) return {'status': 'unauthorized'};
        final id = input['requestId'];
        if (id is! String) return {'status': 'invalid_request'};
        final result = await _call('/$command', {
          'sessionSecret': _session,
          'requestId': id,
        });
        final token = result.remove('token');
        if (command == 'claim' && result['status'] == 'ok' && token is String) {
          _tokens[id] = token;
        }
        return result;
      case 'read':
        final token = _tokens[input['requestId']];
        if (token == null) return {'status': 'unauthorized'};
        return _call('/read', {
          'token': token,
          'itemId': input['itemId'],
          'fieldId': input['fieldId'],
        });
      default:
        return {'status': 'invalid_request'};
    }
  }

  Future<Map<String, dynamic>> _call(
    String path,
    Map<String, dynamic> data,
  ) async {
    try {
      return await (() async {
        final request = await _http.post('127.0.0.1', port, path);
        request.headers.contentType = ContentType.json;
        request.followRedirects = false;
        request.write(jsonEncode(data));
        final response = await request.close();
        final text = await utf8.decoder.bind(response).join();
        return jsonDecode(text) as Map<String, dynamic>;
      })().timeout(const Duration(seconds: 5));
    } on Object {
      return {'status': 'service_unavailable'};
    }
  }
}
