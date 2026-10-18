part of 'info_core.dart';

class SshHostTrustSnapshot {
  SshHostTrustSnapshot({
    required this.id,
    required this.name,
    required List<int> bytes,
    required this.confirmedAt,
  }) : bytes = List.unmodifiable(bytes);
  final String id, name;
  final List<int> bytes;
  final DateTime confirmedAt;
  String get sha256 => 'sha256:${_runtimeSha256(bytes)}';
  Map<String, Object?> toStorageJson() => {
    'id': id,
    'name': name,
    'bytesBase64': base64Encode(bytes),
    'confirmedAt': _useTimestamp(confirmedAt),
  };
  factory SshHostTrustSnapshot.fromStorageJson(Map<String, dynamic> j) =>
      SshHostTrustSnapshot(
        id: j['id'] as String,
        name: j['name'] as String,
        bytes: base64Decode(j['bytesBase64'] as String),
        confirmedAt: DateTime.parse(j['confirmedAt'] as String),
      );
}

String _runtimeSha256(List<int> bytes) => sha256.convert(bytes).toString();

abstract interface class SshHostTrustRepository {
  SshHostTrustSnapshot? get sshHostTrust;
  Future<void> saveSshHostTrust(SshHostTrustSnapshot? snapshot);
}

extension _SshTrustService on InformationService {
  SshHostTrustSnapshot? get _sshHostTrust =>
      _repository is SshHostTrustRepository
      ? (_repository as SshHostTrustRepository).sshHostTrust
      : null;
}

extension SshTrustOwnerAccess on OwnerAccess {
  SshHostTrustSnapshot? get sshKnownHosts => _service._sshHostTrust;
  Future<SshHostTrustSnapshot> configureSshKnownHosts(
    String name,
    List<int> bytes,
  ) {
    final copy = List<int>.of(bytes);
    return _serialize(() async {
      if (_service._repository is! SshHostTrustRepository) {
        throw const CredentialUseFailure('service_unavailable');
      }
      validateSshKnownHosts(name, copy);
      final snapshot = SshHostTrustSnapshot(
        id: _service._secret(),
        name: name,
        bytes: copy,
        confirmedAt: _service._clock().toUtc(),
      );
      await (_service._repository as SshHostTrustRepository).saveSshHostTrust(
        snapshot,
      );
      return snapshot;
    });
  }

  Future<void> clearSshKnownHosts() => _serialize(() async {
    if (_service._repository is! SshHostTrustRepository) {
      throw const CredentialUseFailure('service_unavailable');
    }
    await (_service._repository as SshHostTrustRepository).saveSshHostTrust(
      null,
    );
  });
}

void validateSshKnownHosts(String name, List<int> bytes) {
  try {
    if (name.trim().isEmpty ||
        name.length > 255 ||
        bytes.isEmpty ||
        bytes.length > 1048576) {
      throw const FormatException();
    }
    var count = 0;
    for (final raw in const LineSplitter().convert(utf8.decode(bytes))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.contains('\u0000')) throw const FormatException();
      final parts = line.split(RegExp(r'\s+'));
      var offset = 0;
      if (parts.first.startsWith('@')) {
        if (!{'@revoked', '@cert-authority'}.contains(parts.first)) {
          throw const FormatException();
        }
        offset = 1;
      }
      if (parts.length < offset + 3 ||
          !{
            'ssh-ed25519',
            'ssh-rsa',
            'ecdsa-sha2-nistp256',
            'ecdsa-sha2-nistp384',
            'ecdsa-sha2-nistp521',
            'sk-ssh-ed25519@openssh.com',
            'sk-ecdsa-sha2-nistp256@openssh.com',
          }.contains(parts[offset + 1])) {
        throw const FormatException();
      }
      final key = base64Decode(parts[offset + 2]);
      if (key.length < 8) throw const FormatException();
      final length = (key[0] << 24) | (key[1] << 16) | (key[2] << 8) | key[3];
      if (length < 1 ||
          length > 128 ||
          key.length < length + 8 ||
          utf8.decode(key.sublist(4, 4 + length)) != parts[offset + 1]) {
        throw const FormatException();
      }
      count++;
    }
    if (count == 0) throw const FormatException();
  } on Object {
    throw const AccessFailure('invalid_ssh_known_hosts');
  }
}
