/// Owner-only organization labels. These are not public catalog descriptions.
class InformationDirectory {
  const InformationDirectory(this.id, this.name, this.parentId, this.version);
  final String id, name;
  final String? parentId;
  final int version;
}

class InformationTag {
  const InformationTag(this.id, this.name, this.version);
  final String id, name;
  final int version;
}
