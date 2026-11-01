part of 'info_core.dart';

enum InformationClassificationKind { directory, tag }

enum InformationClassificationAction { create, update, delete }

final class InformationClassificationCommand {
  const InformationClassificationCommand({
    required this.operationId,
    required this.expectedVersion,
    required this.kind,
    required this.action,
    this.targetId,
    this.name = '',
    this.parentId,
    this.removalToken,
  });
  final String operationId, name;
  final int expectedVersion;
  final InformationClassificationKind kind;
  final InformationClassificationAction action;
  final String? targetId, parentId, removalToken;
  String get digest => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'operationId': operationId,
            'version': expectedVersion,
            'kind': kind.name,
            'action': action.name,
            'targetId': targetId,
            'name': name,
            'parentId': parentId,
            'removalToken': removalToken,
          }),
        ),
      )
      .toString();
}

/// Original metadata result, never reconstructed from a subsequently renamed
/// or removed directory/tag. No information bodies are stored here.
final class InformationClassificationReceipt {
  const InformationClassificationReceipt({
    required this.operationId,
    required this.commandDigest,
    required this.expectedVersion,
    required this.version,
    required this.kind,
    required this.action,
    required this.targetId,
    this.directory,
    this.tag,
  });
  final String operationId, commandDigest, targetId;
  final int expectedVersion, version;
  final InformationClassificationKind kind;
  final InformationClassificationAction action;
  final InformationDirectory? directory;
  final InformationTag? tag;
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'commandDigest': commandDigest,
    'expectedVersion': expectedVersion,
    'version': version,
    'kind': kind.name,
    'action': action.name,
    'targetId': targetId,
    'directory': directory == null
        ? null
        : [
            directory!.id,
            directory!.name,
            directory!.parentId,
            directory!.version,
          ],
    'tag': tag == null ? null : [tag!.id, tag!.name, tag!.version],
  };
  factory InformationClassificationReceipt.fromJson(Map<String, dynamic> json) {
    try {
      final d = json['directory'] as List?, t = json['tag'] as List?;
      final value = InformationClassificationReceipt(
        operationId: json['operationId'] as String,
        commandDigest: json['commandDigest'] as String,
        expectedVersion: json['expectedVersion'] as int,
        version: json['version'] as int,
        kind: InformationClassificationKind.values.byName(
          json['kind'] as String,
        ),
        action: InformationClassificationAction.values.byName(
          json['action'] as String,
        ),
        targetId: json['targetId'] as String,
        directory: d == null
            ? null
            : InformationDirectory(
                d[0] as String,
                d[1] as String,
                d[2] as String?,
                d[3] as int,
              ),
        tag: t == null
            ? null
            : InformationTag(t[0] as String, t[1] as String, t[2] as int),
      );
      _validateRecordOperationId(value.operationId);
      bool id(String? id) => id != null && id.isNotEmpty && id.length <= 200;
      bool name(String name) => name.trim().isNotEmpty && name.length <= 200;
      if (json.length != 9 ||
          value.expectedVersion < 1 ||
          value.version <= value.expectedVersion ||
          !id(value.targetId) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(value.commandDigest) ||
          (d != null &&
              (d.length != 4 ||
                  value.directory!.id != value.targetId ||
                  !name(value.directory!.name) ||
                  value.directory!.version < 1 ||
                  (value.directory!.parentId != null &&
                      !id(value.directory!.parentId)))) ||
          (t != null &&
              (t.length != 3 ||
                  value.tag!.id != value.targetId ||
                  !name(value.tag!.name) ||
                  value.tag!.version < 1)) ||
          (value.action == InformationClassificationAction.delete
              ? d != null || t != null
              : value.kind == InformationClassificationKind.directory
              ? d == null || t != null
              : t == null || d != null)) {
        throw const FormatException();
      }
      return value;
    } on Object {
      throw const FormatException('Invalid classification receipt');
    }
  }
}

final class InformationClassificationSnapshot {
  InformationClassificationSnapshot(
    this.version,
    Iterable<InformationDirectory> directories,
    Iterable<InformationTag> tags,
  ) : directories = List.unmodifiable(directories),
      tags = List.unmodifiable(tags);
  final int version;
  final List<InformationDirectory> directories;
  final List<InformationTag> tags;
}

final class InformationTagRemovalPreview {
  const InformationTagRemovalPreview(
    this.token,
    this.tagId,
    this.version,
    this.affectedCount,
  );
  final String token, tagId;
  final int version, affectedCount;
}

final class InformationClassificationChange {
  InformationClassificationChange({
    required this.command,
    required this.targetId,
    this.directory,
    this.tag,
    Iterable<InformationItem> items = const [],
    Iterable<InformationRevision> previous = const [],
    Iterable<ManagedCredential> credentials = const [],
    Iterable<ManagedCredential> previousCredentials = const [],
    required this.validate,
  }) : items = List.unmodifiable(items),
       previous = List.unmodifiable(previous),
       credentials = List.unmodifiable(credentials),
       previousCredentials = List.unmodifiable(previousCredentials);
  final InformationClassificationCommand command;
  final String targetId;
  final InformationDirectory? directory;
  final InformationTag? tag;
  final List<InformationItem> items;
  final List<InformationRevision> previous;
  final List<ManagedCredential> credentials, previousCredentials;
  final void Function() validate;
  InformationClassificationReceipt receipt(int version) =>
      InformationClassificationReceipt(
        operationId: command.operationId,
        commandDigest: command.digest,
        expectedVersion: command.expectedVersion,
        version: version,
        kind: command.kind,
        action: command.action,
        targetId: targetId,
        directory: directory,
        tag: tag,
      );
}

abstract interface class InformationClassificationRepository {
  Future<int> informationClassificationVersion();
  Future<InformationClassificationReceipt?> informationClassificationReceipt(
    String operationId,
  );
  Future<InformationClassificationReceipt> commitInformationClassification(
    InformationClassificationChange change,
  );
}

extension OwnerClassificationOperations on OwnerAccess {
  InformationClassificationRepository get _classificationRepository {
    if (_service._repository
        case final InformationClassificationRepository repo) {
      return repo;
    }
    throw const AccessFailure('unsupported_capability');
  }

  void _classificationAvailable() {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
  }

  Future<InformationClassificationSnapshot>
  informationClassificationSnapshot() => _serialize(() async {
    _classificationAvailable();
    return InformationClassificationSnapshot(
      await _classificationRepository.informationClassificationVersion(),
      directories,
      tags,
    );
  });
  Future<InformationClassificationReceipt?> informationClassificationReceipt(
    String operationId,
  ) => _serialize(() async {
    _classificationAvailable();
    _validateRecordOperationId(operationId);
    return _classificationRepository.informationClassificationReceipt(
      operationId,
    );
  });
  InformationTagRemovalPreview _tagRemovalPreview(String id, int version) {
    if (!tags.any((t) => t.id == id)) {
      throw const AccessFailure('organization_conflict');
    }
    final affected =
        information.where((item) => item.tagIds.contains(id)).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    final affectedCredentials =
        _classificationCredentials.where((c) => c.tagIds.contains(id)).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    final token = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'tagId': id,
              'version': version,
              'items': [
                for (final item in affected) [item.id, item.version],
              ],
              if (affectedCredentials.isNotEmpty)
                'credentials': [
                  for (final c in affectedCredentials) [c.id, c.revision],
                ],
            }),
          ),
        )
        .toString();
    return InformationTagRemovalPreview(
      token,
      id,
      version,
      affected.length + affectedCredentials.length,
    );
  }

  Future<InformationTagRemovalPreview> previewInformationTagRemoval(
    String id,
  ) => _serialize(() async {
    _classificationAvailable();
    return _tagRemovalPreview(
      id,
      await _classificationRepository.informationClassificationVersion(),
    );
  });

  Future<InformationClassificationReceipt> changeInformationClassification(
    InformationClassificationCommand command,
  ) => _serialize(() async {
    _classificationAvailable();
    _validateRecordOperationId(command.operationId);
    final repo = _classificationRepository;
    final old = await repo.informationClassificationReceipt(
      command.operationId,
    );
    if (old != null) {
      if (old.commandDigest != command.digest) {
        throw const AccessFailure('operation_conflict');
      }
      return old;
    }
    final version = await repo.informationClassificationVersion();
    if (command.expectedVersion != version) {
      throw const AccessFailure('organization_conflict');
    }
    final creating = command.action == InformationClassificationAction.create;
    final deleting = command.action == InformationClassificationAction.delete;
    if (creating ? command.targetId != null : command.targetId == null) {
      throw const AccessFailure('invalid_information');
    }
    if (command.kind == InformationClassificationKind.directory
        ? command.removalToken != null
        : command.parentId != null) {
      throw const AccessFailure('invalid_information');
    }
    final id = creating ? _service._secret() : command.targetId!;
    final generation = _service._libraryGeneration;
    InformationDirectory? directory;
    InformationTag? tag;
    var items = <InformationItem>[], previous = <InformationRevision>[];
    var changedCredentials = <ManagedCredential>[],
        previousCredentials = <ManagedCredential>[];
    if (command.kind == InformationClassificationKind.directory) {
      final current = directories.where((d) => d.id == id).firstOrNull;
      if (!creating && current == null) {
        throw const AccessFailure('organization_conflict');
      }
      if (deleting) {
        if (directories.any((d) => d.parentId == id) ||
            information.any((i) => i.directoryId == id) ||
            _classificationCredentials.any((c) => c.directoryId == id)) {
          throw const AccessFailure('directory_not_empty');
        }
      } else {
        if (command.name.trim() == current?.name) {
          _checkOrganizationName(command.name);
        } else {
          _checkDirectoryName(command.name);
        }
        _checkParent(command.parentId, id);
        _uniqueDirectory(command.name, command.parentId, id);
        directory = InformationDirectory(
          id,
          command.name.trim(),
          command.parentId,
          (current?.version ?? 0) + 1,
        );
      }
    } else {
      final current = tags.where((t) => t.id == id).firstOrNull;
      if (!creating && current == null) {
        throw const AccessFailure('organization_conflict');
      }
      if (deleting) {
        if (command.removalToken != _tagRemovalPreview(id, version).token) {
          throw const AccessFailure('organization_conflict');
        }
        final now = _service._clock();
        previousCredentials = _classificationCredentials
            .where((c) => c.tagIds.contains(id))
            .toList();
        changedCredentials = [
          for (final c in previousCredentials)
            c.copy(tagIds: c.tagIds.where((t) => t != id), modifiedAt: now),
        ];
        final originals = information
            .where((i) => i.tagIds.contains(id))
            .toList();
        previous = [for (final i in originals) InformationRevision(i, now)];
        items = [
          for (final i in originals)
            InformationItem(
              i.id,
              i.name,
              i.description,
              i.version + 1,
              i.fields,
              directoryId: i.directoryId,
              tagIds: i.tagIds.where((t) => t != id),
              layout: i.layout,
              createdAt: i.createdAt,
              modifiedAt: now,
            ),
        ];
      } else {
        if (command.removalToken != null) {
          throw const AccessFailure('invalid_information');
        }
        _checkOrganizationName(command.name);
        _uniqueTag(command.name, id);
        tag = InformationTag(
          id,
          command.name.trim(),
          (current?.version ?? 0) + 1,
        );
      }
    }
    return repo.commitInformationClassification(
      InformationClassificationChange(
        command: command,
        targetId: id,
        directory: directory,
        tag: tag,
        items: items,
        previous: previous,
        credentials: changedCredentials,
        previousCredentials: previousCredentials,
        validate: () {
          _classificationAvailable();
          if (generation != _service._libraryGeneration) {
            throw const AccessFailure('library_changed');
          }
          if (deleting &&
              command.kind == InformationClassificationKind.tag &&
              command.removalToken != _tagRemovalPreview(id, version).token) {
            throw const AccessFailure('organization_conflict');
          }
        },
      ),
    );
  });
}
