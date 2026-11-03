import 'library_document.dart';

/// Reading preferences only; no proposal text, file bytes or password values.
class ProposalReadingState {
  final document = DocumentReadingController();
  final selectedOriginals = <String, int>{};
  int page = 0;
  final _children = <String, ProposalReadingState>{};
  ProposalReadingState child(String key) =>
      _children.putIfAbsent(key, ProposalReadingState.new);
  void dispose() {
    document.dispose();
    for (final child in _children.values) {
      child.dispose();
    }
    _children.clear();
    selectedOriginals.clear();
  }
}
