/// Organization metadata discoverable by agents; edits remain owner-approved.
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
