import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';

/// Synthetic delivery adapter. No native path is created or claimed as tested.
class MemoryInformationDeliveries implements InformationDeliveryFiles {
  final bodies = <String, Uint8List>{};
  int sequence = 0;
  bool blocked = false;
  @override
  Future<InformationDeliveryLease> reserve(String name) async =>
      InformationDeliveryLease(
        'C:\\synthetic-private-path-${++sequence}',
        'directory-$sequence',
        name,
        'file-$sequence',
      );
  @override
  Future<void> write(InformationDeliveryLease lease, Uint8List bytes) async {
    bodies[lease.filePath] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> verify(
    InformationDeliveryLease lease,
    int length,
    String digest,
  ) async {
    if (bodies[lease.filePath]?.length != length) {
      throw const RuntimeMaterialFailure('integrity_failed');
    }
  }

  @override
  Future<void> cleanup(InformationDeliveryLease lease) async {
    if (blocked) throw const RuntimeMaterialFailure('cleanup_failed');
    bodies.remove(lease.filePath);
  }
}

class AttachmentUiFixture {
  AttachmentUiFixture._(
    this.root,
    this.repository,
    this.driver,
    this.service,
    this.item,
  );
  final Directory root;
  final MemoryInformationRepository repository;
  final MemoryInformationDeliveries driver;
  final InformationService service;
  InformationItem item;
  OwnerAccess get owner => service.owner;
  static Future<AttachmentUiFixture> create({
    DateTime Function()? clock,
  }) async {
    final root = await Directory.systemTemp.createTemp('attachment-ui-');
    final repository = MemoryInformationRepository();
    final driver = MemoryInformationDeliveries();
    final service = InformationService(
      repository: repository,
      informationDeliveryFiles: driver,
      clock: clock,
    );
    final source = File('${root.path}/fictional-resume.pdf');
    await source.writeAsBytes([0, 255, 7]);
    final form = await service.owner.beginInformationFileDraft();
    final stage = await service.owner.stageInformationFile(
      form,
      source.path,
      mediaType: 'application/pdf',
    );
    final item = await service.owner.commitInformationDraft(
      form,
      'initial',
      InformationDraftInput(
        name: '求职资料',
        description: '虚构求职资料',
        fields: [
          const InformationDraftField.text('姓名', '用于个人资料', '虚构姓名'),
          const InformationDraftField.text(
            '求职说明',
            '个人偏好',
            '未批准的说明',
            kind: FieldKind.textNote,
          ),
          InformationDraftField.stagedFile('简历', '可读取的简历原文件', stage.id),
        ],
      ),
    );
    await service.owner.releaseInformationFileDraft(form);
    return AttachmentUiFixture._(root, repository, driver, service, item);
  }

  Future<void> replace(List<int> bytes) async {
    final source = File('${root.path}/fictional-resume.pdf');
    await source.writeAsBytes(bytes);
    final form = await owner.beginInformationFileDraft();
    final stage = await owner.stageInformationFile(
      form,
      source.path,
      mediaType: 'application/pdf',
    );
    item = await owner.commitInformationDraft(
      form,
      'replace',
      InformationDraftInput(
        itemId: item.id,
        baseVersion: item.version,
        name: item.name,
        description: item.description,
        fields: [
          for (final field in item.fields)
            if (field.kind == FieldKind.file)
              InformationDraftField.stagedFile(
                field.name,
                field.description,
                stage.id,
                fieldId: field.id,
              )
            else
              InformationDraftField.text(
                field.name,
                field.description,
                field.value,
                fieldId: field.id,
                kind: field.kind,
              ),
        ],
      ),
    );
    await owner.releaseInformationFileDraft(form);
  }

  Future<Map<String, Object?>> fetch(
    String session,
    String request,
    String operation,
  ) => service.agent.fetchInformationFile(
    session,
    InformationFileFetchInput.fromJson({
      'protocolVersion': 2,
      'command': 'file-fetch',
      'requestId': request,
      'itemId': item.id,
      'fieldId': item.fields.last.id,
      'operationId': operation,
    }),
  );
  Future<void> close() async {
    driver.blocked = false;
    await service.close();
    final source = File('${root.path}/fictional-resume.pdf');
    if (await source.exists()) await source.delete();
    await root.delete();
  }
}
