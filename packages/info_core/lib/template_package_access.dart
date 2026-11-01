part of 'info_core.dart';

const builtinTemplatePackageIds = {
  'builtin.server',
  'builtin.service',
  'builtin.profile',
};

enum TemplatePackageAction { install, enable, disable, remove }

/// Portable declarative source and Owner configuration, never executable code.
class InstalledTemplatePackage {
  InstalledTemplatePackage({
    required this.id,
    required this.enabled,
    required this.origin,
    List<int>? bytes,
    Map<String, Object?>? legacySource,
  }) : bytes = bytes == null ? null : List.unmodifiable(bytes),
       legacySource = legacySource == null
           ? null
           : Map.unmodifiable({
               ...legacySource,
               if (legacySource['definitionIds'] is Map)
                 'definitionIds': Map<String, Object?>.unmodifiable(
                   Map<String, Object?>.from(
                     legacySource['definitionIds'] as Map,
                   ),
                 ),
             }) {
    if (origin.isEmpty || origin.length > 255 || origin.contains('\u0000')) {
      throw const AccessFailure('invalid_package');
    }
    if (bytes == null) {
      if (!builtinTemplatePackageIds.contains(id) || legacySource != null) {
        throw const AccessFailure('invalid_package');
      }
      definition = null;
    } else {
      definition = DeclarativeTemplatePackageDecoder().decode(
        bytes,
        origin: origin,
        allowMissingTargets: true,
      );
      if (definition!.id != id) throw const AccessFailure('invalid_package');
    }
    if (legacySource != null) {
      if (legacySource.keys.toSet().difference({
            'templateId',
            'version',
            'definitionIds',
          }).isNotEmpty ||
          legacySource['templateId'] is! String ||
          legacySource['version'] is! int ||
          (legacySource['version'] as int) < 1 ||
          legacySource['definitionIds'] is! Map ||
          (legacySource['definitionIds'] as Map).length > 40 ||
          (legacySource['definitionIds'] as Map).entries.any(
            (e) =>
                e.key is! String ||
                e.value is! String ||
                (e.key as String).length > 200 ||
                (e.value as String).length > 200,
          ) ||
          utf8.encode(jsonEncode(legacySource)).length > 32000) {
        throw const AccessFailure('invalid_package');
      }
    }
  }
  final String id, origin;
  final List<int>? bytes;
  final bool enabled;
  final Map<String, Object?>? legacySource;
  bool get builtin => bytes == null;
  late final TemplatePackageDefinition? definition;
  String? get digest => definition?.digest;
  InstalledTemplatePackage withEnabled(bool value) => InstalledTemplatePackage(
    id: id,
    enabled: value,
    origin: origin,
    bytes: bytes,
    legacySource: legacySource,
  );
}

class TemplatePackageCommand {
  TemplatePackageCommand({
    required this.operationId,
    required this.action,
    required this.packageId,
    required this.expectedVersion,
    required this.commandDigest,
    this.expectedDigest,
  }) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$').hasMatch(operationId) ||
        packageId.isEmpty ||
        packageId.length > 128 ||
        expectedVersion < 1 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(commandDigest) ||
        expectedDigest != null &&
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedDigest!)) {
      throw const AccessFailure('invalid_package_operation');
    }
  }
  final String operationId, packageId, commandDigest;
  final String? expectedDigest;
  final TemplatePackageAction action;
  final int expectedVersion;
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'action': action.name,
    'packageId': packageId,
    'expectedVersion': expectedVersion,
    'commandDigest': commandDigest,
    'expectedDigest': expectedDigest,
  };
  factory TemplatePackageCommand.fromJson(Map<String, dynamic> j) =>
      TemplatePackageCommand(
        operationId: j['operationId'] as String,
        action: TemplatePackageAction.values.byName(j['action'] as String),
        packageId: j['packageId'] as String,
        expectedVersion: j['expectedVersion'] as int,
        commandDigest: j['commandDigest'] as String,
        expectedDigest: j['expectedDigest'] as String?,
      );
}

class TemplatePackageReceipt {
  const TemplatePackageReceipt(this.command, this.version, this.digest);
  final TemplatePackageCommand command;
  final int version;
  final String? digest;
  Map<String, Object?> toJson() => {
    'command': command.toJson(),
    'version': version,
    'digest': digest,
  };
  factory TemplatePackageReceipt.fromJson(Map<String, dynamic> j) =>
      TemplatePackageReceipt(
        TemplatePackageCommand.fromJson(
          Map<String, dynamic>.from(j['command'] as Map),
        ),
        j['version'] as int,
        j['digest'] as String?,
      );
}

abstract interface class TemplatePackageRepository {
  List<InstalledTemplatePackage> get installedTemplatePackages;
  Future<TemplatePackageReceipt?> templatePackageReceipt(String id);
  Future<void> commitTemplatePackage(
    TemplatePackageReceipt receipt,
    InstalledTemplatePackage? package, {
    required void Function() validate,
  });
}

extension OwnerTemplatePackages on OwnerAccess {
  int get templatePackageVersion =>
      _service._repository.readSetting('templateCatalogVersion') ?? 1;
  List<InstalledTemplatePackage> get installedTemplatePackages {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    return _service._repository is TemplatePackageRepository
        ? (_service._repository as TemplatePackageRepository)
              .installedTemplatePackages
        : const [];
  }

  TemplatePackageRepository get _templatePackages =>
      _service._repository is TemplatePackageRepository
      ? _service._repository as TemplatePackageRepository
      : throw const AccessFailure('unsupported_capability');
  Future<TemplatePackageReceipt?> templatePackageReceipt(String id) =>
      _serialize(() async {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        return _templatePackages.templatePackageReceipt(id);
      });
  Future<TemplatePackageReceipt> changeTemplatePackage(
    TemplatePackageCommand c, {
    InstalledTemplatePackage? input,
    void Function()? validate,
  }) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final prior = await _templatePackages.templatePackageReceipt(c.operationId);
    if (prior != null) {
      if (jsonEncode(prior.command.toJson()) != jsonEncode(c.toJson())) {
        throw const AccessFailure('operation_conflict');
      }
      return prior;
    }
    void check() {
      if (!serviceAvailable) throw const AccessFailure('service_unavailable');
      if (templatePackageVersion != c.expectedVersion) {
        throw const AccessFailure('catalog_changed');
      }
      validate?.call();
    }

    check();
    final current = installedTemplatePackages
        .where((p) => p.id == c.packageId)
        .firstOrNull;
    InstalledTemplatePackage? next;
    if (c.action == TemplatePackageAction.install) {
      if (input == null ||
          input.builtin ||
          input.id != c.packageId ||
          input.digest != c.expectedDigest) {
        throw const AccessFailure('invalid_package');
      }
      final before = current?.definition, after = input.definition!;
      if (before != null &&
          before.version == after.version &&
          before.digest != after.digest) {
        throw const AccessFailure('package_version_conflict');
      }
      if (before != null) {
        for (final template in after.templates) {
          final old = before.templates
              .where((t) => t.id == template.id)
              .firstOrNull;
          final kinds = {
            for (final f in old?.definition['fields'] as List? ?? [])
              f['key']: f['type'],
          };
          for (final field in template.definition['fields'] as List) {
            if (kinds.containsKey(field['key']) &&
                kinds[field['key']] != field['type']) {
              throw const AccessFailure('definition_identity_conflict');
            }
          }
        }
      }
      if (current == null && installedTemplatePackages.length >= 100) {
        throw const AccessFailure('package_capacity');
      }
      next = input.withEnabled(current?.enabled ?? true);
    } else {
      if (current == null && !builtinTemplatePackageIds.contains(c.packageId)) {
        throw const AccessFailure('package_missing');
      }
      if (input != null) throw const AccessFailure('invalid_package');
      if (c.action == TemplatePackageAction.remove) {
        if (builtinTemplatePackageIds.contains(c.packageId)) {
          throw const AccessFailure('builtin_package');
        }
      } else {
        final original =
            current ??
            InstalledTemplatePackage(
              id: c.packageId,
              enabled: true,
              origin: '内置目录',
            );
        if (c.expectedDigest != null &&
            !original.builtin &&
            c.expectedDigest != original.digest) {
          throw const AccessFailure('catalog_changed');
        }
        next = original.withEnabled(c.action == TemplatePackageAction.enable);
      }
    }
    final receipt = TemplatePackageReceipt(
      c,
      c.expectedVersion + 1,
      next?.digest ?? current?.digest,
    );
    await _templatePackages.commitTemplatePackage(
      receipt,
      next,
      validate: check,
    );
    return receipt;
  });
  void _validatePresentation(InformationDraftInput input) {
    final command = input.command;
    if (input.itemId == null || command?.adoptionPlanId != null) {
      _validateNewTemplate(input.layout?.layout);
    }
    if (command?.adoptionPlanId != null &&
        (input.itemId == null ||
            command!.templateCatalogVersion != templatePackageVersion)) {
      throw const AccessFailure('template_changed');
    }
    if (command?.legacyTemplateId != null) {
      final definition = input.layout?.layout.snapshot['definition'];
      final template = templates
          .where((t) => t.id == command!.legacyTemplateId)
          .firstOrNull;
      if (input.itemId != null ||
          template == null ||
          template.version != command!.legacyTemplateVersion ||
          definition is! Map ||
          definition['legacyTemplateId'] != template.id ||
          definition['legacyTemplateVersion'] != template.version) {
        throw const AccessFailure('template_changed');
      }
    }
  }

  void _validateNewTemplate(InformationLayout? layout) {
    if (layout == null) return;
    final raw = layout.snapshot['definition'];
    if (raw is Map && raw['packageId'] != null && raw['packageId'] is! String) {
      throw const AccessFailure('invalid_information');
    }
    final packageId = raw is Map ? raw['packageId'] as String? : null;
    final builtin = const {
      'server': 'builtin.server',
      'service': 'builtin.service',
      'profile': 'builtin.profile',
    }[layout.typeId];
    final id = packageId ?? builtin;
    if (id == null) return; // Host content forms and plain legacy records.
    final package = installedTemplatePackages
        .where((p) => p.id == id)
        .firstOrNull;
    if (package?.enabled == false) {
      throw const AccessFailure('template_unavailable');
    }
    if (builtinTemplatePackageIds.contains(id)) return;
    final definition = package?.definition;
    if (definition == null ||
        raw is! Map ||
        raw['packageDigest'] != definition.digest ||
        raw['templateVersion'] != definition.version ||
        !definition.templates.any((t) => t.type.id == layout.typeId)) {
      throw const AccessFailure('template_changed');
    }
  }
}
