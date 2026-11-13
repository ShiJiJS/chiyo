import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

void main() {
  test(
    'file HTTP errors retain only recognized delivery facts, not remote diagnostics',
    () async {
      final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const library = 'synthetic-file-errors';
      final connection = AgentConnection(
        AgentConnectionProfile.local(
          port: host.port,
          deviceToken: '${'a' * 22}.${'b' * 43}',
          libraryId: library,
        ),
      );
      addTearDown(() async {
        connection.close();
        await host.close(force: true);
      });
      var status = 403;
      Map<String, Object?> body = {};
      host.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = status;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('x-chiyo-server-id', library);
        request.response.write(
          jsonEncode({...body, 'internalPath': 'PRIVATE-DIAGNOSTIC'}),
        );
        await request.response.close();
      });
      for (final code in [
        'not_authorized',
        'session_ended',
        'not_a_file',
        'invalid_reference',
      ]) {
        final failure = InformationFileFailure(
          code,
          deliveryId: 'original-delivery',
          operationClaimed: true,
        );
        body = failure.toJson();
        status = body['status'] == 'unauthorized' ? 403 : 400;
        final reply = await connection.call('/information-file/fetch', {});
        expect(reply, failure.toJson());
        expect(jsonEncode(reply), isNot(contains('PRIVATE-DIAGNOSTIC')));
      }
      for (final malformed in [
        {'errorCode': 'PRIVATE-DIAGNOSTIC'},
      {'protocolVersion': 2.0},
        {'operationClaimed': 'PRIVATE-DIAGNOSTIC'},
        {'deliveryId': 'invalid\nreference'},
        {'status': 'invalid_request'},
      ]) {
        body = {
          ...const InformationFileFailure('not_authorized').toJson(),
          ...malformed,
        };
        status = 403;
        final reply = await connection.call('/information-file/fetch', {});
        expect(reply.keys, ['status']);
        expect(reply['status'], body['status']);
        expect(jsonEncode(reply), isNot(contains('PRIVATE-DIAGNOSTIC')));
      }
      body = const InformationFileFailure('not_authorized').toJson();
      expect(await connection.call('/catalog', {}), {'status': 'unauthorized'});
    },
  );
}
