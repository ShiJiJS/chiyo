/// A caller-selected credential file. No source path or native picker is
/// embedded in this shared input; platform adapters own actual file selection.
class SelectedCredentialFile {
  SelectedCredentialFile(this.name, Iterable<int> bytes)
    : bytes = List.unmodifiable(bytes);
  final String name;
  final List<int> bytes;
}
