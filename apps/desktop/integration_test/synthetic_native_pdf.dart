// Synthetic two-page PDF for isolated native checks only.
import 'dart:convert';

List<int> syntheticNativePdf({bool inverted = false}) {
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 5 0 R >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 6 0 R >>',
  ];
  for (final color in (inverted ? ['0 0 1', '1 0 0'] : ['1 0 0', '0 0 1'])) {
    final stream = '$color rg 0 0 200 100 re f\n';
    objects.add(
      '<< /Length ${ascii.encode(stream).length} >>\nstream\n${stream}endstream',
    );
  }
  var text = '%PDF-1.4\n';
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(ascii.encode(text).length);
    text += '${i + 1} 0 obj\n${objects[i]}\nendobj\n';
  }
  final xref = ascii.encode(text).length;
  text += 'xref\n0 ${objects.length + 1}\n0000000000 65535 f \n';
  for (final offset in offsets) {
    text += '${offset.toString().padLeft(10, '0')} 00000 n \n';
  }
  text +=
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n';
  return ascii.encode(text);
}
