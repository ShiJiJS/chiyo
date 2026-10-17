import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/approvals.dart';
import 'package:info_desktop/desktop_shell.dart';
import 'package:info_desktop/ui.dart';
import 'capture_credential_use.dart' show loadCredentialUseFonts;

class CaptureRuntimeRepository extends MemoryInformationRepository {
  bool fail = false;
  @override
  Future<void> commitCredentialRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) async {
    if (fail) throw StateError('synthetic audit failure');
    await super.commitCredentialRuntime(
      requests,
      executions,
      fieldGrant: fieldGrant,
      fieldRequest: fieldRequest,
      validate: validate,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadCredentialUseFonts);
  for (final theme in DesktopColorTheme.values) {
    for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
      testWidgets('use states ${theme.name} ${size.width.toInt()}', (
        tester,
      ) async {
        debugDisableShadows = false;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        var now = DateTime(2026, 10, 17, 14, 40);
        final repository = CaptureRuntimeRepository();
        final service = InformationService(
          repository: repository,
          clock: () => now,
          credentialExecutableInspector: (path, receiver) async =>
              ExecutableIdentity(path, 1, 1, 'sha256:capture'),
        );
        await service.owner.setColorTheme(theme);
        final item = await service.owner.createInformation('测试服务器', '', [
          const FieldInput('服务器地址', '', 'test.beichen.example'),
        ]);
        var token = await service.owner.createStringCredential(
          name: 'GitHub · 技能仓库 Token',
          publicPurpose: 'API Token',
          secret: 'synthetic-capture',
        );
        token = await service.owner.updateCredentialMetadata(
          token.id,
          token.revision,
          name: token.name,
          publicPurpose: token.publicPurpose,
          privateNote: '',
          suggestedBinding: 'GH_TOKEN',
          discoverable: true,
        );
        final session = service.agent.openSession('检查技能仓库状态');
        Future<CredentialUseRequest> submit({
          bool fields = false,
          bool long = false,
        }) async => (await tester.runAsync(
          () => service.agent.requestCredentialUse(
            session,
            CredentialUseInput.fromJson({
              'command': 'request-use',
              'purpose': long
                  ? List.filled(160, '核对本次仓库状态。').join()
                  : '核对仓库信息，为同步技能库做准备。',
              'credentials': [
                {
                  'alias': 'github_token',
                  'credentialId': token.id,
                  'version': 1,
                },
              ],
              'launch': {
                'receiver': 'gh_token',
                'executable': r'C:\Program Files\GitHub CLI\gh.exe',
                'argv': [
                  'repo',
                  'view',
                  'northstar/agent-skills',
                  if (long) List.filled(6000, 'x').join(),
                ],
                'cwd': Directory.current.path,
                'env': {
                  'GH_TOKEN': {'secret': 'github_token'},
                },
              },
              if (fields)
                'readFields': [
                  {'itemId': item.id, 'fieldId': item.fields.single.id},
                ],
            }),
          ),
        ))!;
        var request = await submit();
        const key = ValueKey('runtime-state-capture');
        var revision = 0;
        Future<void> mount() async {
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                key: ValueKey('mount-${revision++}'),
                theme: informationTheme(theme),
                debugShowCheckedModeBanner: false,
                home: Scaffold(
                  body: DesktopShell(
                    service: service,
                    port: 0,
                    index: 0,
                    onSelected: (_) {},
                    hasBackups: true,
                    onThemeChanged: (_) {},
                    child: Approvals(
                      service: service,
                      port: 0,
                      focusRequestId: request.id,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        Future<void> capture(String suffix) async {
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(key),
            );
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final directory = Directory(
              '../../docs/development/evidence/28-runtime/r4',
            );
            await directory.create(recursive: true);
            await File(
              '${directory.path}/${theme.name}-${size.width.toInt()}-$suffix.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        Future<void> tap(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        await mount();
        await capture('pending');
        if (theme == DesktopColorTheme.purple) {
          await tap(find.byKey(const ValueKey('use-tip-injection')));
          await capture('tip');
          await tap(find.byKey(const ValueKey('use-tip-injection')));
          await tap(find.text('程序位置与固定计划'));
          await capture('plan');
          await tap(find.text('程序位置与固定计划'));
          await tap(find.text('查看申请明细 ↗'));
          await capture('request-detail');
          await tap(find.text('返回审批'));
          await tap(find.byKey(const ValueKey('credential-use-approve')));
          await capture('approve-dialog');
          repository.fail = true;
          await tap(find.text('确认批准'));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pumpAndSettle();
          await capture('save-failure');
          repository.fail = false;
          await tap(find.text('确认批准'));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pumpAndSettle();
          await capture('approved');
          final material = (await tester.runAsync(
            () => service.agent.consumeCredentialUse(session, request.id),
          ))!;
          await mount();
          await capture('consumed');
          await tap(find.text('查看执行记录 →'));
          await capture('receipt-preparing');
          await tap(find.text('返回审批'));
          final identity = CredentialProcessIdentity.capture(pid)!;
          await tester.runAsync(
            () => service.agent.reportCredentialExecution(
              CredentialExecutionReport(
                executionId: material.executionId,
                executionCapability: material.executionCapability,
                state: 'running',
                pid: pid,
                processCreatedAt: identity.value,
                startedAt: now.toUtc(),
              ),
            ),
          );
          await tester.runAsync(
            () => service.agent.reportCredentialExecution(
              CredentialExecutionReport(
                executionId: material.executionId,
                executionCapability: material.executionCapability,
                state: 'exited',
                pid: pid,
                processCreatedAt: identity.value,
                startedAt: now.toUtc(),
                finishedAt: now.toUtc(),
                exitCode: 7,
              ),
            ),
          );
          identity.close();
          await mount();
          await capture('nonzero');
          await tap(find.text('查看执行记录 →'));
          await capture('receipt-nonzero');
          await tap(find.text('返回审批'));
          request = await submit();
          await tester.runAsync(
            () => service.owner.decideCredentialUse(
              request.id,
              approveCredential: true,
            ),
          );
          final unknown = (await tester.runAsync(
            () => service.agent.consumeCredentialUse(session, request.id),
          ))!;
          // This distinct synthetic record represents a lost process result.
          await tester.runAsync(
            () => service.agent.reportCredentialExecution(
              CredentialExecutionReport(
                executionId: unknown.executionId,
                executionCapability: unknown.executionCapability,
                state: 'unknown',
                errorCode: 'execution_unknown',
                finishedAt: now.toUtc(),
              ),
            ),
          );
          await mount();
          await capture('unknown');
          await tap(find.text('查看执行记录 →'));
          await capture('receipt-unknown');
          await tap(find.text('返回审批'));
          request = await submit();
          await mount();
          await tap(find.text('拒绝请求'));
          await capture('reject-dialog');
          await tap(find.text('确认拒绝'));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pumpAndSettle();
          await capture('denied');
          request = await submit();
          now = now.add(const Duration(minutes: 31));
          await mount();
          await capture('expired');
          request = await submit(fields: true);
          await tester.runAsync(
            () => service.owner.setCredentialEnabled(
              token.id,
              token.revision,
              false,
            ),
          );
          await mount();
          await capture('disabled-fields');
          token = service.owner.credential(token.id);
          token = (await tester.runAsync(
            () => service.owner.setCredentialEnabled(
              token.id,
              token.revision,
              true,
            ),
          ))!;
          request = await submit(long: true, fields: true);
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          await mount();
          await capture('200-long-top');
          await tap(find.byKey(const ValueKey('use-tip-launch')));
          await capture('200-long-launch');
          await tap(find.byKey(const ValueKey('credential-use-approve')));
          await capture('200-approve-dialog');
          await tap(find.text('返回核对'));
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(service.close);
        debugDisableShadows = true;
      });
    }
  }
}
