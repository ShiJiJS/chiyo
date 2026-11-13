part of 'info_core.dart';

/// An approved web destination, not an instruction to search for another form.
/// The device driver produces the structural digest without reading field values.
class BrowserFormTarget {
  BrowserFormTarget._({
    required this.provider,
    required this.instanceId,
    required this.pageId,
    required this.url,
    required this.formSelector,
    required this.fieldSelector,
    required this.structureDigest,
    this.space,
    this.browserAddress,
  });

  final String provider, instanceId, pageId, url;
  final String formSelector, fieldSelector, structureDigest;
  final int? space;
  final String? browserAddress;

  factory BrowserFormTarget.fromJson(Map<String, dynamic> input) {
    _useShape(
      input,
      {
        'provider',
        'instanceId',
        'pageId',
        'url',
        'form',
        'field',
        'structureDigest',
      },
      {'space', 'browserAddress'},
    );
    String text(String key, int max) =>
        _useText(input[key], 'target.$key', max: max, empty: false);
    final provider = text('provider', 16);
    if (!{'ego', 'chrome'}.contains(provider)) {
      throw const CredentialUseFailure('unsupported_receiver');
    }
    final instance = text('instanceId', 256), page = text('pageId', 256);
    final url = text('url', 8192);
    final parsed = Uri.tryParse(url);
    if (parsed == null ||
        !{'http', 'https'}.contains(parsed.scheme) ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty) {
      throw const CredentialUseFailure('invalid_plan', fieldPath: 'target.url');
    }
    final form = text('form', 2048), field = text('field', 2048);
    final digest = text('structureDigest', 64);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const CredentialUseFailure(
        'invalid_plan',
        fieldPath: 'target.structureDigest',
      );
    }
    final rawSpace = input['space'];
    final address = input['browserAddress'];
    if (provider == 'ego') {
      if (rawSpace is! int ||
          rawSpace < 1 ||
          address != null ||
          !RegExp(r'^p[1-9][0-9]*$').hasMatch(page)) {
        throw const CredentialUseFailure('invalid_plan', fieldPath: 'target');
      }
    } else {
      if (rawSpace != null || address is! String) {
        throw const CredentialUseFailure('invalid_plan', fieldPath: 'target');
      }
      chromeAddress(address);
    }
    return BrowserFormTarget._(
      provider: provider,
      instanceId: instance,
      pageId: page,
      url: url,
      formSelector: form,
      fieldSelector: field,
      structureDigest: digest,
      space: rawSpace as int?,
      browserAddress: address as String?,
    );
  }

  /// Public connection selection is limited to an explicit local CDP endpoint.
  /// It does not authorize discovering profiles or changing browser settings.
  static Uri chromeAddress(String value) {
    final uri = Uri.tryParse(value);
    if (value.length > 2048 ||
        value.codeUnits.any((c) => c < 33 || c == 127) ||
        uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        !{'127.0.0.1', 'localhost', '::1', '[::1]'}.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        !{'', '/'}.contains(uri.path) ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const CredentialUseFailure(
        'invalid_plan',
        fieldPath: 'target.browserAddress',
      );
    }
    return uri;
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'instanceId': instanceId,
    'pageId': pageId,
    'url': url,
    'form': formSelector,
    'field': fieldSelector,
    'structureDigest': structureDigest,
    if (space != null) 'space': space,
    if (browserAddress != null) 'browserAddress': browserAddress,
  };

  String get fingerprint => _useFingerprint(toJson());

  void requireSameTarget(BrowserFormTarget observed) {
    if (fingerprint != observed.fingerprint) {
      throw const CredentialUseFailure('browser_target_changed');
    }
  }
}
