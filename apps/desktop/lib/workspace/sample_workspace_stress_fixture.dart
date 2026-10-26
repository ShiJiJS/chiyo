import 'dart:convert';
import 'sample_workspace_fixture.dart';

/// Deterministic, fictional pressure data, separate from the frozen reference.
/// 200 ordinary items + 8 credentials, 50 real directories (+2 virtual scopes),
/// 100 tags. Existing reference records keep their values and identities.
String buildWorkspaceStressFixture({int seed = 902026}) {
  final data = jsonDecode(sampleWorkspaceJson) as Map<String, dynamic>;
  var state = seed & 0x7fffffff;
  int next(int limit) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state % limit;
  }

  final records = (data['records'] as List).cast<Map<String, dynamic>>();
  final directories = (data['directories'] as List)
      .cast<Map<String, dynamic>>();
  final realDirectories = directories
      .where((d) => !['all', 'unfiled'].contains(d['id']))
      .toList();
  final tags = <String>{
    for (final row in [
      ...records,
      ...((data['trash'] as List? ?? []).cast<Map<String, dynamic>>()),
    ])
      ...List<String>.from(row['tags'] ?? []),
  }.toList();
  final originalTagCount = tags.length;
  while (tags.length < 100) {
    tags.add(
      tags.length == originalTagCount
          ? '跨设备维护记录与非常长的中文标签名称 English tag · 用于验证换行和菜单滚动'
          : '压力标签 ${tags.length.toString().padLeft(3, '0')}',
    );
  }
  while (realDirectories.length < 50) {
    final index = realDirectories.length;
    final directory = <String, dynamic>{
      'id': 'stress-directory-$index',
      'name': index == 5
          ? '跨设备维护资料与长期归档目录 · English and 中文长名称'
          : '压力目录 ${index.toString().padLeft(2, '0')}',
      'parent': index % 4 == 0 ? null : realDirectories[index - 1]['id'],
    };
    directories.add(directory);
    realDirectories.add(directory);
  }
  final templates = [
    for (final id in ['azure', 'blinko', 'https', 'oldnote'])
      records.firstWhere(
        (r) => r['id'] == id,
        orElse: () => records.firstWhere((r) => r['kind'] == 'note'),
      ),
  ];
  var ordinary = records.where((r) => r['kind'] != 'credential').length;
  while (ordinary < 200) {
    final index = ordinary++;
    final template = templates[index % templates.length];
    final row = jsonDecode(jsonEncode(template)) as Map<String, dynamic>;
    row['id'] = 'stress-info-${index.toString().padLeft(3, '0')}';
    row['name'] = index == 24
        ? '跨设备资料 · 这是一条用于验证多行标题、连续英文与中文自然换行的非常长名称 · Long record title with mixed content across several teams and environments'
        : index % 9 == 0
        ? '压力资料 · 同名资料'
        : '压力资料 ${index.toString().padLeft(3, '0')} · ${template['name']}';
    row['summary'] =
        '维护批次 ${index % 10} · 合成用途 ${next(1000)} · ${index % 11 == 0 ? '长说明会自然换行，用来检查行尾、独立滚动条和详情区域不会互相遮挡。' : '用于查找、分组、排序与跨页返回。'}';
    row['directory'] = index % 13 == 0
        ? 'unfiled'
        : realDirectories[next(realDirectories.length)]['id'];
    row['tags'] = [tags[index % tags.length], tags[(index + 29) % tags.length]];
    row['updatedAt'] = '2026-10-${(1 + next(26)).toString().padLeft(2, '0')}';
    row['relations'] = {
      'related': ['azure', 'blinko'],
    };
    records.add(row);
  }
  final credential = records.firstWhere((r) => r['kind'] == 'credential');
  while (records.where((r) => r['kind'] == 'credential').length < 8) {
    final row = jsonDecode(jsonEncode(credential)) as Map<String, dynamic>;
    row['id'] = 'stress-credential';
    row['name'] = '压力凭据 · 仅公开说明与关联摘要';
    row['directory'] = realDirectories.last['id'];
    row['tags'] = [tags.last];
    row['relations'] = {};
    records.add(row);
  }
  data['tags'] = tags;
  data['source'] = 'Round09 independent pressure fixture; seed=$seed';
  data['records'] = records;
  data['directories'] = directories;
  return const JsonEncoder.withIndent('  ').convert(data);
}
