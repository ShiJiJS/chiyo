import 'dart:async';
import 'package:info_core/info_core.dart';

class WidgetFillRepository extends MemoryInformationRepository {
  bool fail = false, failTerminal = false;
  @override
  Future<void> commitCredentialRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) async {
    if (fail) throw StateError('synthetic storage failure');
    await super.commitCredentialRuntime(
      requests,
      executions,
      fieldGrant: fieldGrant,
      fieldRequest: fieldRequest,
      validate: validate,
    );
  }

  @override
  Future<void> commitFocusedFillRuntime(
    List<CredentialUseRequest> requests,
    List<FocusedFillOperation> operations, {
    void Function()? validate,
    List<CredentialExecution>? executions,
  }) async {
    if (fail || failTerminal && operations.lastOrNull?.state != FocusedFillState.checking) {
      throw StateError('synthetic storage failure');
    }
    await super.commitFocusedFillRuntime(
      requests,
      operations,
      validate: validate,
      executions: executions,
    );
  }
}

class WidgetFillDriver implements FocusedFillDriver {
  int sends = 0;
  FocusedFillState result = FocusedFillState.sent;
  Completer<void>? wait;
  @override
  Future<PreparedFocusedFill> prepare(
    FocusedFillApplication application,
  ) async {
    await wait?.future;
    return _Prepared(this, application);
  }
}

class _Prepared implements PreparedFocusedFill {
  _Prepared(this.driver, this.application);
  final WidgetFillDriver driver;
  @override
  final FocusedFillApplication application;
  @override
  Future<FocusedFillBatchResult> sendBatch(List<int> units) async {
    driver.sends++;
    return FocusedFillBatchResult(
      driver.result,
      driver.result == FocusedFillState.sent ? null : 'focus_changed',
    );
  }

  @override
  Future<void> close() async {}
}

class WidgetFillFixture {
  WidgetFillFixture(
    this.service,
    this.repository,
    this.driver,
    this.session,
    this.request,
  );
  final InformationService service;
  final WidgetFillRepository repository;
  final WidgetFillDriver driver;
  final String session;
  final CredentialUseRequest request;
  OwnerAccess get owner => service.owner;
  FocusedFillOperationInput operation(String id) =>
      FocusedFillOperationInput.fromJson({
        'protocolVersion': 2,
        'command': 'fill-use',
        'requestId': request.id,
        'operationId': id,
      });
  Future<void> fill(String id) async {
    await service.agent.startFocusedFill(session, operation(id));
    await service.drainFocusedFills();
  }
}

Future<WidgetFillFixture> focusedFillFixture({
  bool approved = false,
  bool long = false,
}) async {
  final repo = WidgetFillRepository(), driver = WidgetFillDriver();
  final service = InformationService(
    repository: repo,
    focusedFillDriver: driver,
    focusedFillApplicationInspector: (a) async => a,
  );
  var c = await service.owner.createStringCredential(
    name: long ? '北辰工作台跨区域项目发布与协作系统登录密码' : '北辰工作台登录密码',
    secret: ' synthetic-widget-password ',
    publicPurpose: '登录密码',
    suggestedBinding: '',
  );
  c = await service.owner.updateCredentialMetadata(
    c.id,
    c.revision,
    name: c.name,
    publicPurpose: c.publicPurpose,
    privateNote: '',
    suggestedBinding: '',
    discoverable: true,
  );
  final session = service.agent.openSession('登录北辰工作台');
  final request = await service.agent.requestFocusedFill(
    session,
    FocusedFillInput.fromJson({
      'protocolVersion': 2,
      'command': 'request-use',
      'purpose': '登录工作台，继续填写项目发布资料。',
      'credentials': [
        {'alias': 'password', 'credentialId': c.id, 'version': c.version},
      ],
      'fill': {
        'application': {
          'executable': long
              ? 'C:\\工具与应用\\项目协作浏览器\\${'Northstar' * 9}\\WorkBrowser.exe'
              : r'C:\Apps\WorkBrowser\WorkBrowser.exe',
          'sha256': '31' * 32,
        },
        'targetHint':
            'https://portal.beichen.example/${long ? 'project-release-' * 9 : ''}login',
      },
    }),
  );
  if (approved) {
    await service.owner.decideCredentialUse(
      request.id,
      approveCredential: true,
    );
  }
  return WidgetFillFixture(service, repo, driver, session, request);
}
