import 'templates.dart';

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
    List<InformationField> fields,
  ) : fields = List.unmodifiable(fields);
  final String id, name, description;
  final int version;
  final List<InformationField> fields;
}

/// Owner-side storage seam. Agent transports never receive this capability.
abstract interface class InformationRepository {
  List<InformationItem> get items;
  Future<void> save(InformationItem item);
  int? readSetting(String key);
  Future<void> writeSetting(String key, int value);
  List<InformationTemplate> get templates;
  Future<void> saveTemplate(InformationTemplate template);
}

class MemoryInformationRepository implements InformationRepository {
  MemoryInformationRepository([Iterable<InformationItem> items = const []]) {
    for (final item in items) {
      _items[item.id] = item;
    }
  }
  final _items = <String, InformationItem>{};
  final _settings = <String, int>{};
  final _templates = <String, InformationTemplate>{};
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
