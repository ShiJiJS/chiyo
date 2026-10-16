/// Public metadata is kept distinct from controlled field values.
class FieldInput {
  const FieldInput(this.name, this.description, this.value);
  final String name;
  final String description;
  final String value;
}

class InformationField {
  const InformationField(
    this.id,
    this.name,
    this.description,
    this.value,
    this.version,
  );
  final String id, name, description, value;
  final int version;
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
}

class MemoryInformationRepository implements InformationRepository {
  MemoryInformationRepository([Iterable<InformationItem> items = const []]) {
    for (final item in items) {
      _items[item.id] = item;
    }
  }
  final _items = <String, InformationItem>{};
  final _settings = <String, int>{};
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
