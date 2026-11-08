import 'dart:convert';
import 'dart:io';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/adoption_transport.dart';
import 'package:info_workspace/plugin_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:info_workspace/workspace_information_codec.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';
import 'support/template_fixture.dart';

void main() {
  test(
    'Owner-only TLS template adoption reuses exact mappings and persisted command while Agent identity cannot preview or save',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final staged = await f.owner.request('POST', '/v1/owner/plugins/stage', {
        'filename': 'synthetic.json',
        'bytes': base64Encode(
          utf8.encode(jsonEncode(syntheticTemplatePackage('1.0.0'))),
        ),
      });
      final plugin = pluginPreviewFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/plugins/previews/${staged['selectionId']}',
        ),
      );
      await f.owner.request(
        'POST',
        '/v1/owner/plugins/changes',
        pluginChangeToJson(
          WorkspacePluginChange(
            operationId: 'install-adoption',
            action: WorkspacePluginAction.install,
            packageId: plugin.package.id,
            expectedVersion: plugin.catalogVersion,
            expectedDigest: plugin.package.digest,
            selectionId: plugin.selectionId,
          ),
        ),
      );
      final definition = Map<String, Object?>.from(
        ((await f.owner.request('GET', '/v1/owner/catalog'))['templates']
                    as List)
                .singleWhere((t) => t['id'] == 'generic')
            as Map,
      );
      final input = WorkspaceCreate(
        operationId: 'original',
        typeId: 'generic',
        name: '合成服务模板转换',
        values: {'body': '## 原文\n\n合成内容'},
        expectedTemplateVersion: definition['templateVersion'] as String,
        expectedTemplateDigest: definition['packageDigest'] as String,
      );
      await f.owner.save(
        input.operationId,
        WorkspaceInformationCodec().create(input, definition),
      );
      final original = (await f.owner.information()).single;
      final detail = WorkspaceInformationCodec().decode(original);
      final body = adoptionDraftToJson(
        WorkspaceAdoptionDraft(
          ref: detail.record.ref,
          typeId: 'local.synthetic/note',
          fields: {
            'format': const WorkspaceFieldMapping(value: 'markdown'),
            'body': const WorkspaceFieldMapping(
              sourceKey: 'body',
              sameMeaning: true,
            ),
          },
        ),
      );
      final agent = HttpClient(context: f.trust);
      try {
        for (final path in ['previews', 'changes']) {
          final request = await agent.postUrl(
            f.owner.address.resolve('/v1/owner/adoption/$path'),
          );
          request.headers.set(
            'authorization',
            'Bearer ${f.profiles.first.deviceToken}',
          );
          request.headers.contentType = ContentType.json;
          request.write(
            jsonEncode(
              path == 'previews'
                  ? body
                  : {
                      'wireVersion': 1,
                      'operationId': 'forbidden',
                      'planId': 'unknown',
                    },
            ),
          );
          final response = await request.close();
          expect(response.statusCode, 401);
          await response.drain<void>();
        }
      } finally {
        agent.close(force: true);
      }
      await expectLater(
        f.owner.request('POST', '/v1/owner/adoption/previews', {
          ...body,
          'rawKey': 'SYNTHETIC',
        }),
        throwsA(
          isA<RemoteFailure>().having((e) => e.code, 'code', 'invalid_request'),
        ),
      );
      final p = adoptionPreviewFromJson(
        await f.owner.request('POST', '/v1/owner/adoption/previews', body),
      );
      expect(p.canApply, isTrue);
      expect(p.result.fieldIds['body'], detail.fieldIds['body']);
      expect((await f.owner.information()).single.version, original.version);
      final change = {
        'wireVersion': 1,
        'operationId': 'apply-once',
        'planId': p.planId,
      };
      final result = await f.owner.request(
        'POST',
        '/v1/owner/adoption/changes',
        change,
      );
      final saved = adoptionReceiptFromJson(result);
      expect(saved.ref, detail.record.ref);
      expect(saved.version, original.version + 1);
      final current = WorkspaceInformationCodec().decode(
        (await f.owner.information()).single,
      );
      expect(current.record.type.id, 'local.synthetic/note');
      expect(current.values['body'], detail.values['body']);
      expect(current.fieldIds['body'], detail.fieldIds['body']);
      expect(
        (await f.owner.receipt('apply-once'))!.command!.adoptionPlanId,
        p.planId,
      );
      await f.reopen();
      expect(
        await f.owner.request('POST', '/v1/owner/adoption/changes', change),
        result,
      );
      expect((await f.owner.information()).single.version, saved.version);
      expect(
        (await f.owner.receipt('apply-once'))!.command!.adoptionPlanId,
        p.planId,
      );
    },
  );
}
