import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';

import 'workspace.dart';

/// Poster lagras som en fil per post: `data/<samling>/<id>.yaml`.
/// Varje ändring sparar den förra versionen under `data/.history/`, och en
/// borttagen post flyttas till `data/.trash/`. Synk mot alt-my-data kommer senare.

Future<Directory> dataDir() async => Directory('${(await getApplicationSupportDirectory()).path}/data');

class Rec {
  Rec(this.collection, this.id, this.values);

  final String collection;
  final String id;
  final Map<String, dynamic> values;

  String str(String field) => values[field]?.toString() ?? '';
}

String _ts() => DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');

/// Gemener a-z, åäö, 0-9 och understreck, börjar med bokstav.
String slug(String s) {
  final out = s.toLowerCase().replaceAll(RegExp(r'[^a-zåäö0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  if (out.isEmpty) return 'post';
  final cut = out.length > 40 ? out.substring(0, 40).replaceAll(RegExp(r'_+$'), '') : out;
  return RegExp(r'^[a-zåäö]').hasMatch(cut) ? cut : 'p_$cut';
}

/// YAML där varje värde skrivs som JSON, som också är giltig YAML.
String _toYaml(Map<String, dynamic> m) =>
    '${[for (final e in m.entries) '${e.key}: ${jsonEncode(e.value)}'].join('\n')}\n';

Future<File> _file(String collection, String id) async => File('${(await dataDir()).path}/$collection/$id.yaml');

Future<List<Rec>> listRecords(String collection) async {
  final dir = Directory('${(await dataDir()).path}/$collection');
  if (!dir.existsSync()) return [];
  final out = <Rec>[];
  for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.yaml'))) {
    final id = f.uri.pathSegments.last.replaceAll('.yaml', '');
    try {
      final y = loadYaml(f.readAsStringSync());
      out.add(Rec(collection, id, Map<String, dynamic>.from(jsonDecode(jsonEncode(y ?? {})) as Map)));
    } catch (_) {
      // En trasig fil hoppas över hellre än att hela listan försvinner.
    }
  }
  return out;
}

Future<Rec?> readRecord(String collection, String id) async {
  final f = await _file(collection, id);
  if (!f.existsSync()) return null;
  return Rec(collection, id, Map<String, dynamic>.from(jsonDecode(jsonEncode(loadYaml(f.readAsStringSync()) ?? {}))));
}

Future<void> _keepHistory(String collection, String id) async {
  final f = await _file(collection, id);
  if (!f.existsSync()) return;
  final h = File('${(await dataDir()).path}/.history/$collection/$id/${_ts()}.yaml');
  h.parent.createSync(recursive: true);
  f.copySync(h.path);
}

/// Sparar en post. Ny post får ett id av titel och datum, till exempel `mammas_födelsedag_2026_10_11`, med `_2`, `_3` vid krock.
Future<Rec> saveRecord(Collection c, Map<String, dynamic> values, {String? id}) async {
  final dir = Directory('${(await dataDir()).path}/${c.name}')..createSync(recursive: true);
  String? recId = id;
  if (recId == null) {
    final base = slug(
      [
        values[c.titleField]?.toString() ?? '',
        if (c.dateField != null) values[c.dateField!.name]?.toString() ?? '',
      ].where((s) => s.isNotEmpty).join(' '),
    );
    recId = base;
    var n = 2;
    while (File('${dir.path}/$recId.yaml').existsSync()) {
      recId = '${base}_${n++}';
    }
  } else {
    await _keepHistory(c.name, recId);
  }
  final clean = {
    for (final e in values.entries)
      if (e.value != null && e.value != '') e.key: e.value,
  };
  File('${dir.path}/$recId.yaml').writeAsStringSync(_toYaml(clean), flush: true);
  return Rec(c.name, recId!, clean);
}

/// Återställer en post till ett tidigare innehåll (används av Ångra).
Future<void> restoreRecord(Rec previous) async {
  final f = await _file(previous.collection, previous.id);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(_toYaml(previous.values), flush: true);
}

Future<void> deleteRecord(Rec r) async {
  final f = await _file(r.collection, r.id);
  if (!f.existsSync()) return;
  final t = File('${(await dataDir()).path}/.trash/${r.collection}/${r.id}.${_ts()}.yaml');
  t.parent.createSync(recursive: true);
  f.renameSync(t.path);
}

/// Antal sparade äldre versioner av en post.
Future<int> historyCount(Rec r) async {
  final d = Directory('${(await dataDir()).path}/.history/${r.collection}/${r.id}');
  return d.existsSync() ? d.listSync().length : 0;
}
