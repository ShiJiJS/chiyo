import 'dart:io';
import 'package:test/test.dart';

Future<({String certificate, String privateKey, String ca})> createTlsFixture(
  Directory root,
) async {
  final cert = '${root.path}/certificate.pem';
  final privateKey = '${root.path}/tls.key';
  final ca = '${root.path}/ca.pem';
  final caKey = '${root.path}/ca.key';
  final csr = '${root.path}/server.csr';
  final extensions = File('${root.path}/server.ext');
  await extensions.writeAsString(
    'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n',
  );
  Future<void> openssl(List<String> args) async {
    final result = await Process.run('openssl', args);
    expect(result.exitCode, 0, reason: 'Synthetic TLS certificate generation');
  }

  await openssl([
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-days',
    '1',
    '-keyout',
    caKey,
    '-out',
    ca,
    '-subj',
    '/CN=Chiyo synthetic CA',
    '-addext',
    'basicConstraints=critical,CA:TRUE',
    '-addext',
    'keyUsage=critical,keyCertSign,cRLSign',
  ]);
  await openssl([
    'req',
    '-new',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-keyout',
    privateKey,
    '-out',
    csr,
    '-subj',
    '/CN=localhost',
  ]);
  await openssl([
    'x509',
    '-req',
    '-in',
    csr,
    '-CA',
    ca,
    '-CAkey',
    caKey,
    '-CAcreateserial',
    '-days',
    '1',
    '-extfile',
    extensions.path,
    '-out',
    cert,
  ]);
  return (certificate: cert, privateKey: privateKey, ca: ca);
}
