import 'dart:convert';
import 'dart:math';
import 'information.dart';
export 'information.dart';

class AccessFailure implements Exception {
  const AccessFailure(this.status);
  final String status;
  @override
  String toString() => 'AccessFailure($status)';
}

class FieldRef {
  const FieldRef(this.itemId, this.fieldId);
  final String itemId;
  final String fieldId;
  Map<String, String> toJson() => {'itemId': itemId, 'fieldId': fieldId};
  @override
  bool operator ==(Object other) =>
      other is FieldRef && other.itemId == itemId && other.fieldId == fieldId;
  @override
  int get hashCode => Object.hash(itemId, fieldId);
}

class RequestReceipt {
  const RequestReceipt(this.id);
  final String id;
}

class _Request {
  _Request(this.id, this.session, this.purpose, this.fields);
  final String id;
  final String session;
  final String purpose;
  final Set<FieldRef> fields;
  ClaimedGrant? grant;
  bool revoked = false;
}

/// In-memory fictional data for the first authorization slice. Not a data store.
class InformationService {
  InformationService({
    required InformationRepository repository,
    DateTime Function()? clock,
  }) : _repository = repository,
       _clock = clock ?? DateTime.now;
  InformationService.fictional({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      _repository = MemoryInformationRepository([
        InformationItem(
          'demo-server',
          'Fictional demo server',
          'Fictional connection information for development only',
          1,
          const [
            InformationField(
              'host',
              'Address',
              'Server host name',
              'demo.example.invalid',
              1,
            ),
            InformationField(
              'username',
              'Username',
              'Login name',
              'demo-user',
              1,
            ),
          ],
        ),
      ]);
  final InformationRepository _repository;
  InformationField? _field(FieldRef ref) {
    for (final item in _repository.items) {
      if (item.id == ref.itemId) {
        for (final field in item.fields) {
          if (field.id == ref.fieldId) return field;
        }
      }
    }
    return null;
  }

  final DateTime Function() _clock;
  late final agent = AgentAccess._(this);
  late final owner = OwnerAccess._(this);
  final _grants = <String, ClaimedGrant>{};
  final _sessions = <String, String>{};
  final _requests = <String, _Request>{};
  bool _closed = false;
  void close() {
    _closed = true;
    _sessions.clear();
    _requests.clear();
    _grants.clear();
  }

  final _random = Random.secure();
  String _secret() =>
      base64Url.encode(List.generate(32, (_) => _random.nextInt(256)));
}

class AgentAccess {
  AgentAccess._(this._service);
  final InformationService _service;
  String openSession(String chatLabel) {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    if (chatLabel.trim().isEmpty || chatLabel.length > 200) {
      throw const AccessFailure('invalid_request');
    }
    final secret = _service._secret();
    _service._sessions[secret] = chatLabel;
    return secret;
  }

  RequestReceipt request(
    String session,
    String purpose,
    List<FieldRef> fields,
  ) {
    if (!_service._sessions.containsKey(session)) {
      throw const AccessFailure('unauthorized');
    }
    if (purpose.trim().isEmpty ||
        purpose.length > 2000 ||
        fields.isEmpty ||
        fields.length > 200 ||
        fields.any((f) => _service._field(f) == null)) {
      throw const AccessFailure('invalid_request');
    }
    final id = _service._secret();
    _service._requests[id] = _Request(
      id,
      session,
      purpose,
      Set.unmodifiable(fields),
    );
    return RequestReceipt(id);
  }

  _Request _request(String session, String id) {
    final request = _service._requests[id];
    if (!_service._sessions.containsKey(session) ||
        request == null ||
        request.session != session) {
      throw const AccessFailure('unauthorized');
    }
    return request;
  }

  Map<String, Object?> status(String session, String id) {
    final request = _request(session, id);
    return {
      'status': request.revoked
          ? 'revoked'
          : (request.grant == null
                ? 'pending'
                : (!_service._clock().isBefore(request.grant!.expiresAt)
                      ? 'expired'
                      : 'approved')),
      'requestId': id,
    };
  }

  ClaimedGrant claim(String session, String id) {
    final request = _request(session, id);
    if (request.revoked) throw const AccessFailure('unauthorized');
    if (request.grant == null) throw const AccessFailure('pending');
    if (!_service._clock().isBefore(request.grant!.expiresAt)) {
      throw const AccessFailure('unauthorized');
    }
    return request.grant!;
  }

  String read(String token, FieldRef field) {
    final grant = _service._grants[token];
    if (grant == null ||
        !_service._clock().isBefore(grant.expiresAt) ||
        !grant.fields.contains(field)) {
      throw const AccessFailure('unauthorized');
    }
    final value = _service._field(field);
    if (value == null) throw const AccessFailure('unauthorized');
    return value.value;
  }

  List<Map<String, Object?>> catalog() => _service._repository.items
      .map(
        (item) => <String, Object?>{
          'id': item.id,
          'name': item.name,
          'description': item.description,
          'fields': item.fields
              .map(
                (field) => {
                  'id': field.id,
                  'name': field.name,
                  'description': field.description,
                },
              )
              .toList(),
        },
      )
      .toList();
}

class ClaimedGrant {
  ClaimedGrant(this.token, List<FieldRef> fields, this.expiresAt)
    : fields = List.unmodifiable(fields);
  final String token;
  final DateTime expiresAt;
  final List<FieldRef> fields;
}

/// Kept inside the desktop process. Never exposed by the agent transport.
class OwnerAccess {
  OwnerAccess._(this._service);
  final InformationService _service;
  List<InformationItem> get information => _service._repository.items;
  Future<void> _writes = Future.value();
  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<InformationItem> createInformation(
    String name,
    String description,
    List<FieldInput> fields,
  ) => _serialize(() async {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    if (name.trim().isEmpty ||
        name.length > 200 ||
        description.length > 2000 ||
        fields.isEmpty ||
        fields.length > 200 ||
        fields.any(
          (f) =>
              f.name.trim().isEmpty ||
              f.name.length > 200 ||
              f.description.length > 2000 ||
              f.value.length > 1000000,
        )) {
      throw const AccessFailure('invalid_information');
    }
    final item = InformationItem(
      _service._secret(),
      name.trim(),
      description,
      1,
      fields
          .map(
            (f) => InformationField(
              _service._secret(),
              f.name.trim(),
              f.description,
              f.value,
              1,
            ),
          )
          .toList(),
    );
    await _service._repository.save(item);
    return item;
  });

  /// Ordinary value correction preserves meaning and identity. Semantic replacement
  /// will be a separate operation; it must never reuse an already authorized ID.
  Future<InformationItem> correctValue(FieldRef ref, String value) =>
      _serialize(() async {
        if (_service._closed) throw const AccessFailure('service_unavailable');
        if (value.length > 1000000 || _service._field(ref) == null)
          throw const AccessFailure('invalid_information');
        final previous = information.firstWhere((i) => i.id == ref.itemId);
        final item = InformationItem(
          previous.id,
          previous.name,
          previous.description,
          previous.version + 1,
          previous.fields
              .map(
                (f) => f.id == ref.fieldId
                    ? InformationField(
                        f.id,
                        f.name,
                        f.description,
                        value,
                        f.version + 1,
                      )
                    : f,
              )
              .toList(),
        );
        await _service._repository.save(item);
        return item;
      });
  List<Map<String, Object?>> get requests => _service._requests.values
      .map(
        (r) => <String, Object?>{
          ..._service.agent.status(r.session, r.id),
          'chatLabel': _service._sessions[r.session],
          'purpose': r.purpose,
          'fields': r.fields.map((f) => f.toJson()).toList(),
          'approvedFields': r.grant?.fields.map((f) => f.toJson()).toList(),
          'expiresAt': r.grant?.expiresAt.toUtc().toIso8601String(),
        },
      )
      .toList();
  void revoke(String requestId) {
    final request = _service._requests[requestId];
    if (request?.grant == null) throw const AccessFailure('invalid_request');
    request!.revoked = true;
    _service._grants.remove(request.grant!.token);
  }

  void approve(String requestId, List<FieldRef> fields) {
    final request = _service._requests[requestId];
    if (request == null ||
        request.grant != null ||
        fields.isEmpty ||
        fields.any((f) => !request.fields.contains(f))) {
      throw const AccessFailure('invalid_request');
    }
    request.grant = ClaimedGrant(
      _service._secret(),
      fields.toSet().toList(),
      _service._clock().add(const Duration(hours: 8)),
    );
    _service._grants[request.grant!.token] = request.grant!;
  }
}
