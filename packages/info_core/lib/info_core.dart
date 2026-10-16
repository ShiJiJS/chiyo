import 'dart:async';
import 'dart:convert';
import 'dart:math';

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
  _Request(
    this.id,
    this.session,
    this.purpose,
    this.fields,
    this.createdAt,
    this.expiresAt,
  );
  final String id;
  final String session;
  final String purpose;
  final Set<FieldRef> fields;
  final DateTime createdAt;
  final DateTime expiresAt;
  String outcome = 'pending';
  ClaimedGrant? grant;
  bool revoked = false;
}

/// In-memory fictional data for the first authorization slice. Not a data store.
class InformationService {
  InformationService.fictional({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  Duration _requestLifetime = const Duration(minutes: 30);
  late final agent = AgentAccess._(this);
  late final owner = OwnerAccess._(this);
  final _grants = <String, ClaimedGrant>{};
  final _sessions = <String, String>{};
  final _requests = <String, _Request>{};
  final _submitted = StreamController<String>.broadcast();
  bool _closed = false;
  void close() {
    _closed = true;
    _sessions.clear();
    _requests.clear();
    _grants.clear();
    _submitted.close();
  }

  final _random = Random.secure();
  String _secret() =>
      base64Url.encode(List.generate(32, (_) => _random.nextInt(256)));

  void _expire(_Request request) {
    if (request.outcome == 'pending' && !_clock().isBefore(request.expiresAt)) {
      request.outcome = 'expired';
    }
  }

  // Decisions are synchronous in the core's owning isolate: validation and
  // transition cannot interleave, so the first terminal decision wins.
  void _finishPending(_Request request, String outcome) {
    _expire(request);
    if (request.outcome != 'pending') {
      throw const AccessFailure('invalid_request');
    }
    request.outcome = outcome;
  }
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
        fields.any(
          (f) =>
              f.itemId != 'demo-server' ||
              !{'host', 'username'}.contains(f.fieldId),
        )) {
      throw const AccessFailure('invalid_request');
    }
    final id = _service._secret();
    final now = _service._clock();
    _service._requests[id] = _Request(
      id,
      session,
      purpose,
      Set.unmodifiable(fields),
      now,
      now.add(_service._requestLifetime),
    );
    _service._submitted.add(id);
    return RequestReceipt(id);
  }

  _Request _request(String session, String id) {
    final request = _service._requests[id];
    if (!_service._sessions.containsKey(session) ||
        request == null ||
        request.session != session) {
      throw const AccessFailure('unauthorized');
    }
    _service._expire(request);
    return request;
  }

  Map<String, Object?> status(String session, String id) {
    final request = _request(session, id);
    return {
      'status': request.revoked
          ? 'revoked'
          : (request.grant == null
                ? request.outcome
                : (!_service._clock().isBefore(request.grant!.expiresAt)
                      ? 'expired'
                      : 'approved')),
      'requestId': id,
      'createdAt': request.createdAt.toUtc().toIso8601String(),
      'requestExpiresAt': request.expiresAt.toUtc().toIso8601String(),
    };
  }

  void cancel(String session, String id) {
    _service._finishPending(_request(session, id), 'cancelled');
  }

  ClaimedGrant claim(String session, String id) {
    final request = _request(session, id);
    if (request.revoked) throw const AccessFailure('unauthorized');
    if (request.grant == null) throw AccessFailure(request.outcome);
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
    return field.fieldId == 'host' ? 'demo.example.invalid' : 'demo-user';
  }

  List<Map<String, Object?>> catalog() => [
    {
      'id': 'demo-server',
      'name': 'Fictional demo server',
      'description': 'Fictional connection information for development only',
      'fields': [
        {'id': 'host', 'name': 'Address', 'description': 'Server host name'},
        {'id': 'username', 'name': 'Username', 'description': 'Login name'},
      ],
    },
  ];
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
  Stream<String> get requestSubmitted => _service._submitted.stream;
  Duration get requestLifetime => _service._requestLifetime;
  void setRequestLifetime(Duration duration) {
    if (duration < const Duration(minutes: 1) ||
        duration > const Duration(days: 7)) {
      throw const AccessFailure('invalid_request');
    }
    _service._requestLifetime = duration;
  }

  List<Map<String, Object?>> get requests => _service._requests.values
      .map(
        (r) => <String, Object?>{
          ..._service.agent.status(r.session, r.id),
          'chatLabel': _service._sessions[r.session],
          'purpose': r.purpose,
          'remainingSeconds': max(
            0,
            r.expiresAt.difference(_service._clock()).inSeconds,
          ),
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

  void deny(String requestId) {
    final request = _service._requests[requestId];
    if (request == null) throw const AccessFailure('invalid_request');
    _service._finishPending(request, 'denied');
  }

  void approve(String requestId, List<FieldRef> fields) {
    final request = _service._requests[requestId];
    if (request != null) _service._expire(request);
    if (request == null ||
        request.outcome != 'pending' ||
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
    request.outcome = 'approved';
  }
}
