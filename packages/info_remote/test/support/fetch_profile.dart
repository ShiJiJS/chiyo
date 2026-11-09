import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';

/// A separate, empty client process. Emits only synthetic-check identities and
/// digests; never prints the connection Token or complete information bodies.
Future<void> main(List<String> args) async {
  final profile = await PrivateConnectionProfileStore(args.single).read();
  if (profile == null) throw StateError('Missing synthetic profile');
  final trust = profile.certificate.isEmpty
      ? null
      : (SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(utf8.encode(profile.certificate)));
  final client = await OwnerClient.connect(
    address: Uri.parse(profile.address),
    token: profile.token,
    expectedServerId: profile.serverId,
    trust: trust,
  );
  try {
    final items = await client.information();
    stdout.writeln(
      jsonEncode({
        'serverId': client.serverId,
        'items': [
          for (final item in items)
            {
              'id': item.id,
              'version': item.version,
              'digest': sha256
                  .convert(utf8.encode(jsonEncode(informationToJson(item))))
                  .toString(),
            },
        ],
      }),
    );
  } finally {
    client.close();
  }
}
