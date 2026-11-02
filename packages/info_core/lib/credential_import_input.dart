import 'dart:convert';

/// Private proposal material. Never project this object into an ordinary field,
/// public catalog, status response or owner workspace resource.
class CredentialImportInput {
  CredentialImportInput._(
    this.source,
    this.contextExposed,
    Iterable<int>? material,
    this.fileName,
  ) : material = material == null ? null : List.unmodifiable(material) {
    if (!{'owner', 'agentString', 'agentFile'}.contains(source) ||
        source == 'owner' && contextExposed ||
        source == 'agentString' && !contextExposed ||
        source != 'agentFile' && fileName != null) {
      throw const FormatException('Invalid credential input source');
    }
    final bytes = this.material;
    if (source != 'owner' && bytes == null) {
      throw const FormatException('Missing credential material');
    }
    if (bytes != null) {
      if (bytes.isEmpty ||
          bytes.length > (source == 'agentFile' ? 1048576 : 65536) ||
          bytes.any((b) => b < 0 || b > 255)) {
        throw const FormatException('Invalid credential material');
      }
      if (source != 'agentFile') {
        if (utf8.decode(bytes).contains('\u0000')) {
          throw const FormatException('Invalid credential string');
        }
      }
    }
    if (source == 'agentFile' &&
        (fileName == null ||
            fileName!.isEmpty ||
            fileName == '.' ||
            fileName == '..' ||
            fileName!.length > 255 ||
            fileName!.contains(RegExp(r'[/\\:\x00-\x1f]')))) {
      throw const FormatException('Invalid credential filename');
    }
  }

  factory CredentialImportInput.owner() =>
      CredentialImportInput._('owner', false, null, null);
  factory CredentialImportInput.agentString(String secret) =>
      CredentialImportInput._('agentString', true, utf8.encode(secret), null);
  factory CredentialImportInput.agentFile(
    String fileName,
    List<int> bytes, {
    bool contextExposed = false,
  }) => CredentialImportInput._('agentFile', contextExposed, bytes, fileName);

  final String source;
  final bool contextExposed;
  final List<int>? material;
  final String? fileName;
  bool get ready => material != null;
  bool get isFile => source == 'agentFile';

  CredentialImportInput withOwnerSecret(String secret) {
    if (source != 'owner') {
      throw const FormatException('Not an owner password input');
    }
    return CredentialImportInput._('owner', false, utf8.encode(secret), null);
  }

  Map<String, Object?> get metadata => {
    'source': source,
    'contextExposed': contextExposed,
    'materialReady': ready,
    if (fileName != null) 'fileName': fileName,
    if (material != null) 'byteLength': material!.length,
  };
  Map<String, Object?> get submissionJson => {
    'source': source,
    'contextExposed': contextExposed,
    if (source == 'agentString') 'secret': utf8.decode(material!),
    if (source == 'agentFile') ...{
      'fileName': fileName,
      'bytes': base64Encode(material!),
    },
  };
  Map<String, Object?> toPrivateJson() => {
    'source': source,
    'contextExposed': contextExposed,
    if (fileName != null) 'fileName': fileName,
    if (material != null) 'material': base64Encode(material!),
  };
  factory CredentialImportInput.fromJson(Map<String, dynamic> json) {
    if (json.keys.any(
          (k) => !{
            'source',
            'contextExposed',
            'secret',
            'fileName',
            'bytes',
          }.contains(k),
        ) ||
        json['contextExposed'] is! bool) {
      throw const FormatException('Invalid credential input');
    }
    final source = json['source'];
    if (source == 'owner' && json.length == 2 && !json['contextExposed']) {
      return CredentialImportInput.owner();
    }
    if (source == 'agentString' &&
        json.length == 3 &&
        json['contextExposed'] &&
        json['secret'] is String) {
      return CredentialImportInput.agentString(json['secret'] as String);
    }
    if (source == 'agentFile' && json.length == 4 && json['bytes'] is String) {
      return CredentialImportInput.agentFile(
        json['fileName'] as String,
        base64Decode(json['bytes'] as String),
        contextExposed: json['contextExposed'] as bool,
      );
    }
    throw const FormatException('Invalid credential input');
  }
  factory CredentialImportInput.fromPrivateJson(Map<String, dynamic> json) {
    if (json.keys.any(
      (k) => !{'source', 'contextExposed', 'fileName', 'material'}.contains(k),
    )) {
      throw const FormatException('Invalid private credential input');
    }
    return CredentialImportInput._(
      json['source'] as String,
      json['contextExposed'] as bool,
      json['material'] == null
          ? null
          : base64Decode(json['material'] as String),
      json['fileName'] as String?,
    );
  }
}
