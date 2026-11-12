import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// A saved CA keeps normal chain/hostname validation. A saved leaf additionally
/// pins that exact certificate, allowing a LAN address chosen after deployment.
/// This fallback never accepts another certificate or a global trust override.
HttpClient serverHttpClient({String certificate = '', SecurityContext? trust}) {
  final context =
      trust ??
      (certificate.isEmpty
          ? null
          : (SecurityContext(withTrustedRoots: false)
              ..setTrustedCertificatesBytes(utf8.encode(certificate))));
  final client = HttpClient(context: context);
  if (certificate.isNotEmpty) {
    final match = RegExp(
      r'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----',
    ).firstMatch(certificate);
    if (match == null)
      throw const FormatException('Invalid server certificate');
    final expected = sha256
        .convert(base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), '')))
        .toString();
    client.badCertificateCallback = (peer, _, _) {
      final now = DateTime.now();
      return now.isAfter(peer.startValidity) &&
          now.isBefore(peer.endValidity) &&
          sha256.convert(peer.der).toString() == expected;
    };
  }
  return client;
}
