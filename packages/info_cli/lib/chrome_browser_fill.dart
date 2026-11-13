import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'browser_form_script.dart';
import 'browser_fill_types.dart';
export 'browser_fill_types.dart';

/// Only fixed public error codes leave the browser transport. Browser error
/// messages may echo evaluated source, including material, and are discarded.
typedef ChromeFormInspection = BrowserFormInspection;

/// A caller-selected local Chrome CDP endpoint. Does not launch a browser,
/// discover profiles, activate tabs or alter remote-debugging settings.
class ChromeBrowserFill {
  ChromeBrowserFill(String address, {this.timeout = const Duration(seconds: 5)})
    : address = BrowserFormTarget.chromeAddress(address);
  final Uri address;
  final Duration timeout;
  static const _maxReply = 1024 * 1024;

  Future<Object?> _get(String path) async {
    final http = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await http.getUrl(address.resolve(path));
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        throw const BrowserFillFailure('browser_unavailable');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > _maxReply) {
          throw const BrowserFillFailure('browser_response_invalid');
        }
        bytes.addAll(chunk);
      }
      return jsonDecode(utf8.decode(bytes));
    } on BrowserFillFailure {
      rethrow;
    } on Object {
      throw const BrowserFillFailure('browser_unavailable');
    } finally {
      http.close(force: true);
    }
  }

  Uri _socket(Object? value, String kind, {String? target}) {
    final uri = value is String ? Uri.tryParse(value) : null;
    if (uri == null ||
        !{'ws', 'wss'}.contains(uri.scheme) ||
        !{'127.0.0.1', 'localhost', '::1', '[::1]'}.contains(uri.host) ||
        uri.port != address.port ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.length != 3 ||
        uri.pathSegments[0] != 'devtools' ||
        uri.pathSegments[1] != kind ||
        uri.pathSegments[2].isEmpty ||
        target != null && uri.pathSegments[2] != target) {
      throw const BrowserFillFailure('browser_response_invalid');
    }
    return uri;
  }

  Future<String> _instance() async {
    final response = await _get('/json/version');
    if (response is! Map<String, dynamic>) {
      throw const BrowserFillFailure('browser_response_invalid');
    }
    final socket = _socket(response['webSocketDebuggerUrl'], 'browser');
    return sha256.convert(utf8.encode(socket.toString())).toString();
  }

  Future<List<Map<String, dynamic>>> _pages() async {
    final response = await _get('/json/list');
    if (response is! List || response.length > 10000) {
      throw const BrowserFillFailure('browser_response_invalid');
    }
    return [
      for (final row in response)
        if (row is Map<String, dynamic> && row['type'] == 'page') row,
    ];
  }

  Future<Map<String, Object?>> pages() async {
    final instance = await _instance();
    final pages = await _pages();
    return {
      'instanceId': instance,
      'browserAddress': address.toString(),
      'pages': [
        for (final page in pages)
          if (page['id'] is String && page['url'] is String)
            {
              'id': page['id'],
              'url': page['url'],
              'title': page['title'] ?? '',
            },
      ],
    };
  }

  Future<({String instance, Uri socket})> _select(
    String page,
    String url,
  ) async {
    final instance = await _instance();
    final matches = (await _pages()).where((row) => row['id'] == page).toList();
    if (matches.length != 1 || matches.single['url'] != url) {
      throw const BrowserFillFailure('destination_changed');
    }
    return (
      instance: instance,
      socket: _socket(
        matches.single['webSocketDebuggerUrl'],
        'page',
        target: page,
      ),
    );
  }

  Future<Map<String, dynamic>> _evaluate(
    _CdpPage page,
    String expression,
  ) async {
    final response = await page.call('Runtime.evaluate', {
      'expression': expression,
      'uniqueContextId': page.context,
      'returnByValue': true,
      'awaitPromise': false,
    });
    final result = response['result'];
    if (response.containsKey('exceptionDetails') ||
        result is! Map ||
        result['value'] is! Map<String, dynamic>) {
      throw const BrowserFillFailure('browser_operation_failed');
    }
    return result['value'] as Map<String, dynamic>;
  }

  Future<ChromeFormInspection> inspect({
    required String tab,
    required String url,
    required String form,
    required String field,
  }) async {
    final selected = await _select(tab, url);
    final page = await _CdpPage.open(selected.socket, timeout);
    try {
      await page.pinDocument();
      return await _inspect(page, selected.instance, tab, url, form, field);
    } finally {
      await page.close();
    }
  }

  Future<ChromeFormInspection> _inspect(
    _CdpPage page,
    String instance,
    String tab,
    String url,
    String form,
    String field,
  ) async {
    final receipt = await _evaluate(
      page,
      browserFormExpression(url: url, form: form, field: field),
    );
    if (receipt['status'] != 'ready' ||
        receipt['structure'] is! Map<String, dynamic>) {
      throw BrowserFillFailure(_receiptCode(receipt));
    }
    final structure = receipt['structure'] as Map<String, dynamic>;
    final target = BrowserFormTarget.fromJson({
      'provider': 'chrome',
      'instanceId': instance,
      'browserAddress': address.toString(),
      'pageId': tab,
      'url': url,
      'form': form,
      'field': field,
      'structureDigest': sha256
          .convert(utf8.encode(jsonEncode(structure)))
          .toString(),
    });
    return ChromeFormInspection(target, structure);
  }

  Future<Map<String, Object?>> fill(
    BrowserFormTarget approved,
    String password, {
    Future<void> Function()? beforeDispatch,
  }) async {
    if (approved.provider != 'chrome' ||
        approved.browserAddress != address.toString()) {
      return const {'status': 'refused', 'code': 'destination_changed'};
    }
    final bytes = utf8.encode(password);
    if (bytes.isEmpty ||
        bytes.length > 65536 ||
        password.contains(RegExp(r'[\r\n\x00]'))) {
      return const {'status': 'refused', 'code': 'unsupported_password_value'};
    }
    _CdpPage? page;
    var dispatched = false;
    try {
      final selected = await _select(approved.pageId, approved.url);
      if (selected.instance != approved.instanceId) {
        throw const BrowserFillFailure('destination_changed');
      }
      page = await _CdpPage.open(selected.socket, timeout);
      await page.pinDocument();
      final checked = await _inspect(
        page,
        selected.instance,
        approved.pageId,
        approved.url,
        approved.formSelector,
        approved.fieldSelector,
      );
      approved.requireSameTarget(checked.target);
      if (beforeDispatch != null) {
        try {
          await beforeDispatch().timeout(timeout);
        } on Object catch (error) {
          throw BrowserFillFailure(browserDispatchError(error));
        }
      }
      // Once sent, a lost CDP reply cannot prove that no input occurred.
      dispatched = true;
      final receipt = await _evaluate(
        page,
        browserFormExpression(
          url: approved.url,
          form: approved.formSelector,
          field: approved.fieldSelector,
          expectedStructure: checked.structure,
          password: password,
        ),
      );
      if (!{'filled', 'refused', 'unknown'}.contains(receipt['status'])) {
        throw const BrowserFillFailure('browser_response_invalid');
      }
      return {
        'status': receipt['status'],
        if (receipt['code'] != null) 'code': _receiptCode(receipt),
      };
    } on Object catch (error) {
      return {
        'status': dispatched ? 'unknown' : 'refused',
        'code': error is BrowserFillFailure
            ? error.code
            : browserDispatchError(error),
      };
    } finally {
      await page?.close();
    }
  }
}

String _receiptCode(Map<String, dynamic> receipt) =>
    browserReceiptCode(receipt);

class _CdpPage {
  _CdpPage(this.socket, this.timeout) {
    subscription = socket.listen(
      _receive,
      onError: (Object _) => _failed(),
      onDone: _failed,
    );
  }
  final WebSocket socket;
  final Duration timeout;
  late final StreamSubscription<Object?> subscription;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _contexts = <Map<String, dynamic>>[];
  late final String context;
  var _next = 0;
  static Future<_CdpPage> open(Uri uri, Duration timeout) async {
    try {
      return _CdpPage(
        await WebSocket.connect(uri.toString()).timeout(timeout),
        timeout,
      );
    } on Object {
      throw const BrowserFillFailure('browser_unavailable');
    }
  }

  void _receive(Object? event) {
    try {
      if (event is! String || utf8.encode(event).length > 1024 * 1024) {
        _failed();
        return;
      }
      final value = jsonDecode(event);
      if (value is! Map<String, dynamic>) return;
      if (value['method'] == 'Runtime.executionContextCreated') {
        final observed = (value['params'] as Map?)?['context'];
        if (observed is Map<String, dynamic> && _contexts.length < 1024) {
          _contexts.add(observed);
        }
      }
      if (value['id'] is! int) return;
      final pending = _pending.remove(value['id']);
      if (pending == null) return;
      if (value['error'] != null || value['result'] is! Map<String, dynamic>) {
        pending.completeError(
          const BrowserFillFailure('browser_operation_failed'),
        );
      } else {
        pending.complete(value['result'] as Map<String, dynamic>);
      }
    } on Object {
      _failed();
    }
  }

  void _failed() {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final value in pending) {
      value.completeError(const BrowserFillFailure('browser_unavailable'));
    }
  }

  Future<void> pinDocument() async {
    // Listen before Runtime.enable. Numeric context IDs can be reused after
    // navigation; never fall back to a numeric ID or the default document.
    await call('Runtime.enable', {});
    final tree = await call('Page.getFrameTree', {});
    final frame = ((tree['frameTree'] as Map?)?['frame'] as Map?)?['id'];
    if (frame is! String || frame.isEmpty) {
      throw const BrowserFillFailure('browser_operation_failed');
    }
    final name =
        'chiyo-fill-${base64Url.encode(List.generate(16, (_) => Random.secure().nextInt(256)))}';
    final world = await call('Page.createIsolatedWorld', {
      'frameId': frame,
      'worldName': name,
    });
    final matches = _contexts
        .where(
          (c) =>
              c['id'] == world['executionContextId'] &&
              c['name'] == name &&
              (c['auxData'] as Map?)?['frameId'] == frame,
        )
        .toList();
    if (matches.length != 1 ||
        matches.single['uniqueId'] is! String ||
        (matches.single['uniqueId'] as String).isEmpty) {
      throw const BrowserFillFailure('browser_operation_failed');
    }
    context = matches.single['uniqueId'] as String;
    _contexts.clear();
  }

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, Object?> params,
  ) async {
    final id = ++_next;
    final pending = Completer<Map<String, dynamic>>();
    _pending[id] = pending;
    try {
      socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
      return await pending.future.timeout(timeout);
    } on Object {
      throw const BrowserFillFailure('browser_operation_failed');
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> close() async {
    _failed();
    await subscription.cancel();
    await socket.close();
  }
}
