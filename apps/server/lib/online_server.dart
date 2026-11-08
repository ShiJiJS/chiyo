import 'agent_devices.dart';
import 'agent_gateway.dart';
import 'package:info_core/agent_server.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/information_transport.dart';
import 'package:info_core/protocol_json.dart';
import 'package:crypto/crypto.dart';
import 'package:info_workspace/owner_workspace_approvals.dart';
import 'package:info_workspace/workspace_records.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/owner_agent_templates.dart';
import 'package:info_workspace/owner_workspace_template_packages.dart';
import 'package:info_workspace/plugin_transport.dart';

/// User management is a separate authenticated surface from the Agent API.
/// This host never starts a local credential executor or owns a desktop.
final class OnlineServer {
  OnlineServer._(
    this._http,
    this._runtime,
    this._ownerToken,
    this.serverId,
    this._devices,
  ) : _agents = AgentGateway(AgentProtocol(_runtime.service.agent), _devices),
      _approvals = OwnerWorkspaceApprovals(owner: _runtime.service.owner),
      _plugins = OwnerWorkspaceTemplatePackages(
        owner: _runtime.service.owner,
        changed: () {},
      ) {
    _service.owner.configureInformationTemplates(
      () => currentAgentTemplates(_service.owner),
    );
    _http.listen(
      _handle,
      onError: (Object error, StackTrace stack) {
        // Rejected TLS peers and disconnected clients are transport failures,
        // not unhandled host errors. Certificate verification stays enabled.
        if (error is! HandshakeException &&
            error is! SocketException &&
            error is! HttpException) {
          Zone.current.handleUncaughtError(error, stack);
        }
      },
    );
  }
  final HttpServer _http;
  final OnlineInformationRuntime _runtime;
  InformationService get _service => _runtime.service;
  final String _ownerToken;
  final String serverId;
  final AgentDeviceRegistry _devices;
  final AgentGateway _agents;
  final OwnerWorkspaceApprovals _approvals;
  final OwnerWorkspaceTemplatePackages _plugins;
  int get port => _http.port;

  static Future<OnlineServer> start({
    required OnlineInformationRuntime runtime,
    required AgentDeviceRegistry devices,
    required SecurityContext tls,
    required String ownerToken,
    required String serverId,
    InternetAddress? address,
    int port = 0,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(ownerToken) ||
        !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(serverId)) {
      throw const FormatException('Invalid server configuration');
    }
    final http = await HttpServer.bindSecure(
      address ?? InternetAddress.loopbackIPv4,
      port,
      tls,
    );
    return OnlineServer._(http, runtime, ownerToken, serverId, devices);
  }

  Future<void> close() async {
    await _http.close(force: true);
    _plugins.dispose();
  }

  bool _authenticated(String? value) {
    final expected = 'Bearer $_ownerToken'.codeUnits;
    final supplied = (value ?? '').codeUnits;
    var difference = expected.length ^ supplied.length;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ (i < supplied.length ? supplied[i] : 0);
    }
    return difference == 0;
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/json') {
      throw const FormatException('Expected JSON');
    }
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024) {
        throw const FormatException('Request too large');
      }
      bytes.addAll(chunk);
    }
    return decodeProtocolObject(utf8.decode(bytes), maxBytes: 2 * 1024 * 1024);
  }

  Future<String> _observation() async {
    final owner = _service.owner;
    final requests = await owner.informationRequestInbox();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              owner.templatePackageVersion,
              [
                for (final i in owner.information) [i.id, i.version],
              ],
              [
                for (final d in owner.directories) [d.id, d.name, d.parentId],
              ],
              [
                for (final t in owner.tags) [t.id, t.name],
              ],
              [
                for (final r in requests)
                  [
                    r.id,
                    r.state.name,
                    r.sessionEnded,
                    r.applicationClosed,
                    r.decisionPending,
                    r.grantExpiresAt?.toIso8601String(),
                    r.fields.map((f) => f.toJson()).toList(),
                    r.approvedFields?.map((f) => f.toJson()).toList(),
                  ],
              ],
            ]),
          ),
        )
        .toString();
  }

  Future<void> _handle(HttpRequest request) async {
    int status = 500;
    Object result = {'error': 'service_failure'};
    Future<void> reply(int code, Object value) async {
      status = code;
      result = value;
    }

    Map<String, dynamic>? parsedBody;
    Future<void> route() async {
      try {
        // No browser management surface is part of this version.
        if (request.headers.value('origin') != null) {
          await reply(401, {'error': 'unauthorized'});
          return;
        }
        final expectedServer = request.headers.value('x-chiyo-server-id');
        if (expectedServer != null && expectedServer != serverId) {
          await reply(409, {'error': 'server_changed'});
          return;
        }
        final path = request.uri.pathSegments;
        if (path.length >= 3 && path.take(2).join('/') == 'v1/agent') {
          final authorization = request.headers.value('authorization') ?? '';
          if (!authorization.startsWith('Bearer ')) {
            await reply(401, {'error': 'unauthorized'});
            return;
          }
          final bearer = authorization.substring(7);
          // Authenticate before parsing body or consulting the shared protocol.
          await _devices.authenticate(bearer);
          if (request.method != 'POST') {
            await reply(405, {'error': 'method_not_allowed'});
            return;
          }
          final result = await _agents.dispatch(
            bearer,
            '/${path.skip(2).join('/')}',
            parsedBody!,
          );
          await reply(200, result);
          return;
        }
        if (!_authenticated(request.headers.value('authorization'))) {
          await reply(401, {'error': 'unauthorized'});
          return;
        }
        if (request.method == 'GET' && request.uri.path == '/v1/server') {
          await reply(200, {
            'protocolVersion': 1,
            'serverId': serverId,
            'workspaceObservation': await _observation(),
          });
        } else if (path.length >= 3 &&
            path.take(3).join('/') == 'v1/owner/plugins') {
          if (path.length == 3 && request.method == 'GET') {
            await reply(200, pluginCatalogToJson(await _plugins.load()));
          } else if (path.length == 4 &&
              path.last == 'stage' &&
              request.method == 'POST') {
            final body = parsedBody!;
            if (body.length != 2 ||
                body['filename'] is! String ||
                body['bytes'] is! String ||
                (body['bytes'] as String).length > 1398104) {
              throw const FormatException('Invalid package input');
            }
            final staged = _plugins.stageBytes(
              body['filename'] as String,
              base64Decode(body['bytes'] as String),
            );
            await reply(200, {
              'selectionId': staged.selectionId,
              'filename': staged.filename,
              'byteLength': staged.byteLength,
            });
          } else if (path.length == 5 &&
              path[3] == 'previews' &&
              request.method == 'GET') {
            await reply(
              200,
              pluginPreviewToJson(await _plugins.previewInstall(path.last)),
            );
          } else if (path.length == 5 &&
              path[3] == 'selections' &&
              request.method == 'DELETE') {
            await _plugins.releaseCandidate(path.last);
            await reply(200, {'status': 'released'});
          } else if (path.length == 4 &&
              path.last == 'changes' &&
              request.method == 'POST') {
            await reply(
              200,
              pluginReceiptToJson(
                await _plugins.change(pluginChangeFromJson(parsedBody!)),
              ),
            );
          } else if (path.length == 5 &&
              path[3] == 'operations' &&
              request.method == 'GET') {
            final receipt = await _plugins.receipt(path.last);
            await reply(
              receipt == null ? 404 : 200,
              receipt == null
                  ? {'error': 'operation_not_found'}
                  : pluginReceiptToJson(receipt),
            );
          } else {
            await reply(404, {'error': 'not_found'});
          }
        } else if (path.length >= 4 &&
            path.take(3).join('/') == 'v1/owner/approvals') {
          if (path.length == 4 &&
              path.last == 'query' &&
              request.method == 'POST') {
            await reply(
              200,
              approvalResultsToJson(
                await _approvals.query(
                  approvalQueryFromJson(parsedBody!),
                  keepSelection: parsedBody['keepSelection'] as String?,
                ),
              ),
            );
          } else if (path.length == 4 &&
              path.last == 'decisions' &&
              request.method == 'POST') {
            await reply(
              200,
              approvalReceiptToJson(
                await _approvals.change(approvalChangeFromJson(parsedBody!)),
              ),
            );
          } else if (path.length == 5 &&
              path[3] == 'operations' &&
              request.method == 'GET') {
            final receipt = await _approvals.receipt(path.last);
            await reply(
              receipt == null ? 404 : 200,
              receipt == null
                  ? {'error': 'operation_not_found'}
                  : approvalReceiptToJson(receipt),
            );
          } else if (path.length == 4 && request.method == 'GET') {
            await reply(
              200,
              approvalDetailToJson(await _approvals.read(path.last)),
            );
          } else {
            await reply(404, {'error': 'not_found'});
          }
        } else if (request.uri.path == '/v1/owner/devices' &&
            request.method == 'GET') {
          await reply(200, {'devices': await _devices.metadata()});
        } else if (request.uri.path == '/v1/owner/devices' &&
            request.method == 'POST') {
          final input = parsedBody!;
          if (input.keys.any((k) => !const {'operationId', 'name'}.contains(k)))
            throw const FormatException('Invalid device request');
          final device = await _devices.enroll(
            input['operationId'] as String,
            input['name'] as String,
          );
          await reply(200, {
            'deviceId': device.identity.id,
            'name': device.identity.name,
            'generation': device.identity.generation,
            'deviceToken': device.bearer,
          });
        } else if (request.method == 'POST' &&
            path.length == 5 &&
            path.take(3).join('/') == 'v1/owner/devices' &&
            path.last == 'revoke') {
          final input = parsedBody!;
          if (input.length != 1 || input['operationId'] is! String)
            throw const FormatException('Invalid device request');
          await _devices.revoke(input['operationId'] as String, path[3]);
          await reply(200, {'status': 'revoked', 'deviceId': path[3]});
        } else if (request.method == 'GET' &&
            request.uri.path == '/v1/owner/catalog') {
          final classification = await _service.owner
              .informationClassificationSnapshot();
          await reply(200, {
            'version': classification.version,
            'summary': {
              'records':
                  _service.owner.information.length +
                  _service.owner.credentials.length,
              'pending': _service.owner.queryInbox(limit: 1).pendingCount,
              'proposals': _service.owner.queryProposals(limit: 1).pendingCount,
            },
            'directories': [
              for (final d in _service.owner.directories)
                {'id': d.id, 'name': d.name, 'parentId': d.parentId},
            ],
            'tags': [
              for (final t in _service.owner.tags) {'id': t.id, 'name': t.name},
            ],
            'templates': _plugins.templates.values.toList(),
          });
        } else if (request.method == 'GET' &&
            request.uri.path == '/v1/owner/summaries') {
          await reply(200, {
            'items': [
              for (final item in _service.owner.information)
                {
                  ...informationToJson(item),
                  'fields': [],
                  if (item.layout != null)
                    'layout': InformationLayout(
                      typeId: item.layout!.typeId,
                      snapshot: {
                        if (item.layout!.snapshot['type'] != null)
                          'type': item.layout!.snapshot['type'],
                      },
                      fieldIds: {},
                    ).toJson(),
                },
            ],
          });
        } else if (request.method == 'GET' &&
            path.length == 4 &&
            path.take(3).join('/') == 'v1/owner/information') {
          final item = _service.owner.information
              .where((i) => i.id == path.last)
              .firstOrNull;
          await reply(
            item == null ? 404 : 200,
            item == null ? {'error': 'not_found'} : informationToJson(item),
          );
        } else if (request.method == 'GET' &&
            request.uri.path == '/v1/owner/information') {
          await reply(200, {
            'items': _service.owner.information.map(informationToJson).toList(),
          });
        } else if (path.length == 4 &&
            path.take(3).join('/') == 'v1/owner/operations' &&
            request.method == 'GET') {
          final receipt = await _service.owner.informationRecordReceipt(
            path.last,
          );
          await reply(
            receipt == null ? 404 : 200,
            receipt?.toJson() ?? {'error': 'operation_not_found'},
          );
        } else if (path.length == 4 &&
            path.take(3).join('/') == 'v1/owner/saves' &&
            request.method == 'POST') {
          final receipt = await _service.owner.saveInformationRecord(
            path.last,
            informationDraftFromJson(parsedBody!),
          );
          await reply(200, receipt.toJson());
        } else {
          await reply(404, {'error': 'not_found'});
        }
      } on WorkspaceFailure catch (e) {
        await reply(e.code == 'not_found' ? 404 : 409, {'error': e.code});
      } on AccessFailure catch (e) {
        await reply(e.status == 'unauthorized' ? 401 : 409, {
          'error': e.status,
          'status': e.status,
        });
      } on CredentialUseFailure catch (e) {
        await reply(400, e.toJson());
      } on FormatException {
        await reply(400, {'error': 'invalid_request'});
      } on TypeError {
        await reply(400, {'error': 'invalid_request'});
      } on Object {
        // Never reflect field values, tokens, filesystem paths or exception text.
        try {
          await reply(500, {'error': 'service_failure'});
        } on Object {
          /* disconnected */
        }
      }
    }

    try {
      // Reject unauthenticated peers and parse bounded request bodies before
      // entering the serialized business queue. No network await holds its lock.
      if (request.headers.value('origin') != null) {
        throw const AccessFailure('unauthorized');
      }
      final path = request.uri.pathSegments;
      final authorization = request.headers.value('authorization') ?? '';
      if (path.length >= 3 && path.take(2).join('/') == 'v1/agent') {
        if (!authorization.startsWith('Bearer '))
          throw const AccessFailure('unauthorized');
        await _devices.authenticate(authorization.substring(7));
      } else if (!_authenticated(authorization)) {
        throw const AccessFailure('unauthorized');
      }
      if (request.method == 'POST') parsedBody = await _body(request);
      await _runtime.run(route);
    } on AccessFailure catch (e) {
      status = e.status == 'unauthorized' ? 401 : 409;
      result = {'error': e.status, 'status': e.status};
    } on FormatException {
      status = 400;
      result = {'error': 'invalid_request'};
    } on Object {
      status = 500;
      result = {'error': 'service_failure'};
    }
    // Never publish content, new session proofs or approval success before the
    // encrypted runtime checkpoint has committed. A failed checkpoint replaces
    // the staged response above with a fixed error.
    try {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('cache-control', 'no-store');
      request.response.headers.set('x-chiyo-server-id', serverId);
      request.response.write(jsonEncode(result));
      await request.response.close();
    } on Object {
      /* disconnected */
    }
  }
}
