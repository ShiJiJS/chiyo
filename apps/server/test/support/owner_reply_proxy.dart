import 'dart:convert';
import 'dart:io';

/// Real TLS forwarding with narrowly controlled response loss. It never logs
/// request bodies or credentials; production has no fault-injection switches.
class OwnerReplyProxy {
  OwnerReplyProxy._(this.server, this.upstream, this.target, this.serverId) {
    server.listen(_serve);
  }
  final HttpServer server;
  final HttpClient upstream;
  final Uri Function() target;
  final String serverId;
  String? dropNextPath, failGetPrefix;
  String? failPostPrefix, failPostsAfterDrop, failGetsAfterDrop;
  final requests = <String, int>{};
  Uri get address => Uri.parse('https://127.0.0.1:${server.port}');
  static Future<OwnerReplyProxy> start({
    required SecurityContext tls,
    required SecurityContext trust,
    required Uri Function() target,
    required String serverId,
  }) async => OwnerReplyProxy._(
    await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls),
    HttpClient(context: trust),
    target,
    serverId,
  );
  Future<void> _serve(HttpRequest incoming) async {
    final path = incoming.uri.path;
    final key = '${incoming.method} $path';
    requests[key] = (requests[key] ?? 0) + 1;
    try {
      if ((incoming.method == 'GET' &&
              failGetPrefix != null &&
              path.startsWith(failGetPrefix!)) ||
          (incoming.method == 'POST' &&
              failPostPrefix != null &&
              path.startsWith(failPostPrefix!))) {
        incoming.response.statusCode = 503;
        incoming.response.headers.set('x-chiyo-server-id', serverId);
        incoming.response.headers.contentType = ContentType.json;
        incoming.response.write(jsonEncode({'error': 'synthetic_unavailable'}));
        await incoming.response.close();
        return;
      }
      final request = await upstream.openUrl(
        incoming.method,
        target().resolve(incoming.uri.toString()),
      );
      for (final header in [
        'authorization',
        'content-type',
        'x-chiyo-server-id',
      ]) {
        final value = incoming.headers.value(header);
        if (value != null) request.headers.set(header, value);
      }
      await request.addStream(incoming);
      final response = await request.close();
      final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
      if (path == dropNextPath) {
        dropNextPath = null;
        if (failPostsAfterDrop != null) failPostPrefix = failPostsAfterDrop;
        if (failGetsAfterDrop != null) failGetPrefix = failGetsAfterDrop;
        (await incoming.response.detachSocket(writeHeaders: false)).destroy();
        return;
      }
      incoming.response.statusCode = response.statusCode;
      incoming.response.headers.contentType = ContentType.json;
      final identity = response.headers.value('x-chiyo-server-id');
      if (identity != null)
        incoming.response.headers.set('x-chiyo-server-id', identity);
      incoming.response.add(bytes);
      await incoming.response.close();
    } on Object {
      try {
        await incoming.response.close();
      } on Object {
        /* disconnected */
      }
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    upstream.close(force: true);
  }
}
