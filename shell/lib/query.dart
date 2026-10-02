import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'records.dart';
import 'workspace.dart';

/// En sparad fråga (`apps/<app>/<namn>.query.yaml`): en lista över poster som
/// räknas fram på telefonen. Frågan är text, så AI:n kan skriva den utan att
/// någonsin se posterna.
///
///   label: Open tasks
///   from: important_matters          # en samling, en lista, eller { type: dated_entry }
///   where:
///     done: false                    # lika med (ett tomt bool-fält räknas som false)
///     date: { from: today, to: today+14d }
///     title: { contains: tand }
///     note: { empty: false }
///   sort: date                       # -date för omvänd ordning
///   limit: 20
class Query {
  Query({
    required this.name,
    required this.app,
    required this.appLabel,
    required this.label,
    required this.from,
    required this.type,
    required this.where,
    required this.sort,
    required this.desc,
    required this.limit,
  });

  final String name;
  final String app;
  final String appLabel;
  final String label;
  final List<String> from;
  final String? type;
  final Map<String, dynamic> where;
  final String? sort;
  final bool desc;
  final int? limit;

  static Query parse(String name, String app, String appLabel, String source, {Map<String, dynamic> lang = const {}}) {
    final m = Map<String, dynamic>.from(jsonDecode(jsonEncode(loadYaml(source) ?? {})) as Map);
    final rawFrom = m['from'];
    final from = <String>[];
    String? type;
    if (rawFrom is String) {
      from.add(rawFrom);
    } else if (rawFrom is List) {
      from.addAll(rawFrom.map((e) => e.toString()));
    } else if (rawFrom is Map && rawFrom['type'] != null) {
      type = rawFrom['type'].toString();
    } else {
      throw FormatException('$name saknar from');
    }
    final where = Map<String, dynamic>.from((m['where'] as Map?) ?? const {});
    for (final e in where.entries) {
      if (e.value is Map) {
        final bad = (e.value as Map).keys.where((k) => !_ops.contains(k)).toList();
        if (bad.isNotEmpty) throw FormatException('$name: okänt villkor ${bad.join(', ')} för ${e.key}');
        for (final k in ['from', 'to']) {
          final v = (e.value as Map)[k];
          if (v is String && v.startsWith('today') && relativeDate(v) == null) {
            throw FormatException('$name: kan inte läsa datumet $v');
          }
        }
      }
    }
    var sort = m['sort']?.toString();
    var desc = false;
    if (sort != null && sort.startsWith('-')) {
      desc = true;
      sort = sort.substring(1);
    }
    String? tr(List<String> path) {
      dynamic v = lang;
      for (final p in path) {
        if (v is! Map) return null;
        v = v[p];
      }
      return v is String ? v : null;
    }

    return Query(
      name: name,
      app: app,
      appLabel: appLabel,
      label: tr(['queries', name, 'label']) ?? m['label']?.toString() ?? name,
      from: from,
      type: type,
      where: where,
      sort: sort,
      desc: desc,
      limit: m['limit'] is int ? m['limit'] as int : null,
    );
  }

  /// Samlingarna frågan läser från.
  List<Collection> sources(List<Collection> all) => [
    for (final c in all)
      if (type != null ? c.type == type : from.contains(c.name)) c,
  ];

  bool matches(Map<String, dynamic> values, DateTime today) {
    for (final e in where.entries) {
      if (!_test(values[e.key], e.value, today)) return false;
    }
    return true;
  }
}

const _ops = {'from', 'to', 'contains', 'empty', 'not'};

/// "today", "today+3d", "today-2w", "today+1m" → datum.
DateTime? relativeDate(String s, [DateTime? now]) {
  final m = RegExp(r'^today(?:([+-])(\d+)([dwm]))?$').firstMatch(s.trim());
  if (m == null) return null;
  final t = now ?? DateTime.now();
  final base = DateTime(t.year, t.month, t.day);
  if (m[1] == null) return base;
  final n = int.parse(m[2]!) * (m[1] == '-' ? -1 : 1);
  return switch (m[3]) {
    'd' => DateTime(base.year, base.month, base.day + n),
    'w' => DateTime(base.year, base.month, base.day + 7 * n),
    _ => DateTime(base.year, base.month + n, base.day),
  };
}

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Gör om "today+7d" till ett datum; allt annat lämnas som det är.
dynamic _resolve(dynamic v, DateTime today) {
  if (v is String) {
    final d = relativeDate(v, today);
    if (d != null) return _iso(d);
  }
  return v;
}

bool _isEmpty(dynamic v) => v == null || v == '' || v == false;

int _compare(dynamic a, dynamic b) {
  if (a is num && b is num) return a.compareTo(b);
  final na = num.tryParse('$a'), nb = num.tryParse('$b');
  if (na != null && nb != null) return na.compareTo(nb);
  return '$a'.compareTo('$b');
}

bool _test(dynamic value, dynamic cond, DateTime today) {
  if (cond is Map) {
    if (cond.containsKey('empty') && _isEmpty(value) != (cond['empty'] == true)) return false;
    if (cond.containsKey('not') && _equals(value, _resolve(cond['not'], today))) return false;
    if (cond.containsKey('contains')) {
      if (!'${value ?? ''}'.toLowerCase().contains('${cond['contains']}'.toLowerCase())) return false;
    }
    for (final k in ['from', 'to']) {
      if (!cond.containsKey(k)) continue;
      if (value == null || value == '') return false;
      final c = _compare(value, _resolve(cond[k], today));
      if (k == 'from' ? c < 0 : c > 0) return false;
    }
    return true;
  }
  return _equals(value, _resolve(cond, today));
}

bool _equals(dynamic value, dynamic cond) {
  if (cond is bool) return (value == true) == cond;
  if (cond == null) return value == null || value == '';
  return '${value ?? ''}'.toLowerCase() == '$cond'.toLowerCase();
}

/// Kör frågan mot posterna på telefonen.
Future<List<(Collection, Rec)>> runQuery(
  Query q,
  List<Collection> collections, {
  Future<List<Rec>> Function(String collection) load = listRecords,
  DateTime? now,
}) async {
  final t = now ?? DateTime.now();
  final today = DateTime(t.year, t.month, t.day);
  final out = <(Collection, Rec)>[];
  for (final c in q.sources(collections)) {
    for (final r in await load(c.name)) {
      if (q.matches(r.values, today)) out.add((c, r));
    }
  }
  out.sort((a, b) {
    final field = q.sort ?? a.$1.dateField?.name ?? a.$1.titleField;
    final c = _compare(a.$2.values[field] ?? '', b.$2.values[field] ?? '');
    return q.desc ? -c : c;
  });
  return q.limit != null && out.length > q.limit! ? out.sublist(0, q.limit!) : out;
}
