import 'organization.dart';
export 'organization.dart';
import 'templates.dart';
import 'import_proposals.dart';
import 'update_proposals.dart';

enum FieldKind { structured, textNote }

/// Public metadata is kept distinct from controlled field values.
class FieldInput {
  const FieldInput(
    this.name,
    this.description,
    this.value, {
    this.kind = FieldKind.structured,
  });
  final String name;
  final String description;
  final String value;
  final FieldKind kind;
}

class InformationField {
  const InformationField(
    this.id,
    this.name,
    this.description,
    this.value,
    this.version, {
    this.kind = FieldKind.structured,
  });
  final String id, name, description, value;
  final int version;
  final FieldKind kind;
}

class InformationItem {
  InformationItem(
    this.id,
    this.name,
    this.description,
    this.version,
    List<InformationField> fields, {
    this.directoryId,
    Iterable<String> tagIds = const [],
  }) : fields = List.unmodifiable(fields),
       tagIds = List.unmodifiable(tagIds);
  final String id, name, description;
  final int version;
  final List<InformationField> fields;
  final String? directoryId;
  final List<String> tagIds;
}

/// Owner-side storage seam. Agent transports never receive this capability.
abstract interface class InformationRepository {
  List<InformationItem> get items;
  Future<void> save(InformationItem item);
  List<InformationDirectory> get directories;
  List<InformationTag> get tags;
  Future<void> saveDirectory(InformationDirectory directory);
  Future<void> saveTag(InformationTag tag);
  int? readSetting(String key);
  Future<void> writeSetting(String key, int value);
  List<InformationTemplate> get templates;
  Future<void> saveTemplate(InformationTemplate template);
  List<ImportProposal> get importProposals;
  Future<void> saveImportProposal(ImportProposal proposal);

  /// Commits the entire batch and its terminal proposal state atomically.
  Future<void> confirmImportProposal(
    ImportProposal proposal,
    List<InformationItem> items,
  );
  List<UpdateProposal> get updateProposals;
  List<InformationRevision> get informationRevisions;
  Future<void> saveUpdateProposal(UpdateProposal proposal);
  Future<void> saveInformationRevision(
    InformationItem item,
    InformationRevision previous,
  );
  Future<void> confirmUpdateProposal(
    UpdateProposal proposal,
    InformationItem item,
    InformationRevision previous,
  );
}

class MemoryInformationRepository implements InformationRepository {
  MemoryInformationRepository([Iterable<InformationItem> items = const []]) {
    for (final item in items) {
      _items[item.id] = item;
    }
  }
  final _items = <String, InformationItem>{};
  final _settings = <String, int>{};
  final _directories = <String, InformationDirectory>{};
  final _tags = <String, InformationTag>{};
  @override
  List<InformationDirectory> get directories =>
      List.unmodifiable(_directories.values);
  @override
  List<InformationTag> get tags => List.unmodifiable(_tags.values);
  @override
  Future<void> saveDirectory(InformationDirectory directory) async =>
      _directories[directory.id] = directory;
  @override
  Future<void> saveTag(InformationTag tag) async => _tags[tag.id] = tag;
  final _templates = <String, InformationTemplate>{};
  final _proposals = <String, ImportProposal>{};
  final _updates = <String, UpdateProposal>{};
  final _revisions = <InformationRevision>[];
  @override
  List<UpdateProposal> get updateProposals =>
      List.unmodifiable(_updates.values);
  @override
  List<InformationRevision> get informationRevisions =>
      List.unmodifiable(_revisions);
  @override
  Future<void> saveUpdateProposal(UpdateProposal proposal) async {
    _updates[proposal.id] = proposal;
  }

  @override
  Future<void> saveInformationRevision(
    InformationItem item,
    InformationRevision previous,
  ) async {
    _items[item.id] = item;
    _revisions.add(previous);
  }

  @override
  Future<void> confirmUpdateProposal(
    UpdateProposal proposal,
    InformationItem item,
    InformationRevision previous,
  ) async {
    _items[item.id] = item;
    _revisions.add(previous);
    _updates[proposal.id] = proposal;
  }

  @override
  List<ImportProposal> get importProposals =>
      List.unmodifiable(_proposals.values);
  @override
  Future<void> saveImportProposal(ImportProposal proposal) async {
    _proposals[proposal.id] = proposal;
  }

  @override
  Future<void> confirmImportProposal(
    ImportProposal proposal,
    List<InformationItem> items,
  ) async {
    for (final item in items) {
      _items[item.id] = item;
    }
    _proposals[proposal.id] = proposal;
  }

  @override
  List<InformationTemplate> get templates =>
      List.unmodifiable(_templates.values);
  @override
  Future<void> saveTemplate(InformationTemplate template) async {
    _templates[template.id] = template;
  }

  @override
  List<InformationItem> get items => List.unmodifiable(_items.values);
  @override
  Future<void> save(InformationItem item) async {
    _items[item.id] = item;
  }

  @override
  int? readSetting(String key) => _settings[key];
  @override
  Future<void> writeSetting(String key, int value) async {
    _settings[key] = value;
  }
}
