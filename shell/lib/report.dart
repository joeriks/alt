import 'package:yaml/yaml.dart';

import 'query.dart';
import 'records.dart';
import 'workspace.dart';

/// Rapporter i Markdown, skrivna till datarepot vid varje synk så att datan går att läsa på GitHub.
///
/// Två slag:
/// - Översikter som skrivs av sig själva: `README.md` i roten och i varje okrypterad samlings mapp.
/// - Egna rapporter: `apps/<app>/<namn>.report.md` i receptrepot, som blir `_reports/<namn>.md` i datarepot
///   och ett menyval i appen.
///
/// En rapport har ett YAML-huvud som väljer poster som en fråga (from, where, sort, limit) och
/// kan gruppera dem (group: ett fält, eller date:week / date:month). Under huvudet står Markdown
/// med platshållare:
///
///   ---
///   label: Responsibilities
///   from: responsibilities
///   sort: header
///   ---
///   # Ansvarsområden
///
///   {{#each}}
///   ## {{header}}
///   {{description}}
///   {{#children under_areas}}
///   - [{{title}}]({{@link}}){{#if description}}: {{description}}{{/if}}
///   {{/children}}
///   {{/each}}
///
/// - `{{fält}}` visar värdet: datum som "fre 3 okt", bool som ja/nej, en koppling som postens titel.
/// - `{{@title}}`, `{{@link}}` (länk till postfilen), `{{@collection}}` (samlingens namn).
/// - `{{#each}}…{{/each}}` upprepas för varje post. Med group får varje grupp en `## rubrik` först.
/// - `{{#children <samling>}}…{{/children}}` upprepas för poster i samlingen som kopplar till posten.
/// - `{{#if fält}}…{{/if}}` och `{{#unless fält}}…{{/unless}}`.
/// - Utanför each: `{{today}}`, `{{count}}` och `{{label}}`.

/// Markören som visar att en fil är skriven av alt och får skrivas över.
const generatedMark = '<!-- skriven av alt: ändringar här skrivs över vid nästa synk -->';
const reportsDir = '_reports';

class Report {
  Report({
    required this.name,
    required this.app,
    required this.appLabel,
    required this.label,
    required this.query,
    required this.group,
    required this.body,
  });

  final String name;
  final String app;
  final String appLabel;
  final String label;
  final Query query;
  final String? group;
  final String body;

  String get path => 'apps/$app/$name.report.md';
  String get output => '$reportsDir/$name.md';

  static Report parse(String name, String app, String appLabel, String source, {Map<String, dynamic> lang = const {}}) {
    final lines = source.split('\n');
    if (lines.isEmpty || lines.first.trim() != '---') throw FormatException('$name: börjar inte med ---');
    final end = lines.indexWhere((l) => l.trim() == '---', 1);
    if (end < 0) throw FormatException('$name: huvudet slutar inte med ---');
    final head = lines.sublist(1, end).join('\n');
    final m = loadYaml(head);
    final q = Query.parse(name, app, appLabel, head, lang: lang);
    final tr = lang['reports'] is Map ? (lang['reports'] as Map)[name] : null;
    final body = lines.sublist(end + 1).join('\n');
    _parse(body); // kastar om mallen inte går att läsa
    return Report(
      name: name,
      app: app,
      appLabel: appLabel,
      label: (tr is Map ? tr['label']?.toString() : null) ?? (m is Map ? m['label']?.toString() : null) ?? name,
      query: q,
      group: m is Map ? m['group']?.toString() : null,
      body: body,
    );
  }
}

// ---------------------------------------------------------------- mallen

sealed class _Node {}

class _Text extends _Node {
  _Text(this.text);
  final String text;
}

class _Var extends _Node {
  _Var(this.name);
  final String name;
}

class _Section extends _Node {
  _Section(this.kind, this.arg, this.children);
  final String kind;
  final String arg;
  final List<_Node> children;
}

final _tag = RegExp(r'\{\{\s*([#/]?)([@\w.]+)(?:\s+([\w.]+))?\s*\}\}');
const _sections = {'each', 'children', 'if', 'unless'};

List<_Node> _parse(String text) {
  // Ett block-tagg ensamt på en rad tar bort hela raden, så att mallen kan skrivas luftigt.
  final src = text.replaceAllMapped(RegExp(r'^[ \t]*(\{\{\s*[#/][^}]*\}\})[ \t]*\r?\n', multiLine: true), (m) => m[1]!);
  final root = <_Node>[];
  final stack = <(String, String, List<_Node>)>[];
  var cur = root;
  var at = 0;
  for (final m in _tag.allMatches(src)) {
    if (m.start > at) cur.add(_Text(src.substring(at, m.start)));
    at = m.end;
    final kind = m[1]!, name = m[2]!, arg = m[3] ?? '';
    if (kind == '#') {
      if (!_sections.contains(name)) throw FormatException('okänt block {{#$name}}');
      if ((name == 'children' || name == 'if' || name == 'unless') && arg.isEmpty) {
        throw FormatException('{{#$name}} behöver ett namn');
      }
      stack.add((name, arg, cur));
      cur = <_Node>[];
    } else if (kind == '/') {
      if (stack.isEmpty || stack.last.$1 != name) throw FormatException('{{/$name}} utan början');
      final (n, a, parent) = stack.removeLast();
      parent.add(_Section(n, a, cur));
      cur = parent;
    } else {
      cur.add(_Var(name));
    }
  }
  if (stack.isNotEmpty) throw FormatException('{{#${stack.last.$1}}} slutar aldrig');
  if (at < src.length) cur.add(_Text(src.substring(at)));
  return root;
}

// ---------------------------------------------------------------- visning

const _days = ['mån', 'tis', 'ons', 'tor', 'fre', 'lör', 'sön'];
const _months = ['jan', 'feb', 'mar', 'apr', 'maj', 'jun', 'jul', 'aug', 'sep', 'okt', 'nov', 'dec'];
const _monthsLong = [
  'januari',
  'februari',
  'mars',
  'april',
  'maj',
  'juni',
  'juli',
  'augusti',
  'september',
  'oktober',
  'november',
  'december',
];

String showDate(String iso, DateTime today) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}${d.year != today.year ? ' ${d.year}' : ''}';
}

int _isoWeek(DateTime d) {
  final thursday = d.add(Duration(days: 4 - d.weekday));
  final first = DateTime(thursday.year, 1, 1);
  return 1 + thursday.difference(first).inDays ~/ 7;
}

String _esc(String s) => s.replaceAll('\r', '').replaceAll('\n', ' ').replaceAll('|', '\\|');
String _href(String path) => path.split('/').map(Uri.encodeComponent).join('/');

/// Det rapporterna läser: samlingarna och deras poster.
class ReportData {
  ReportData(this.collections, this.records, this.today);
  final List<Collection> collections;

  /// Samling → poster.
  final Map<String, List<Rec>> records;
  final DateTime today;

  Collection? collection(String name) => collections.where((c) => c.name == name).firstOrNull;
  List<Rec> of(String c) => records[c] ?? const [];
  Rec? find(String c, String id) => of(c).where((r) => r.id == id).firstOrNull;

  /// Läser posterna från telefonen.
  static Future<ReportData> load(List<Collection> collections, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    return ReportData(collections, {
      for (final c in collections) c.name: await listRecords(c.name),
    }, DateTime(t.year, t.month, t.day));
  }

  String show(Collection c, Field f, Rec r) {
    final v = r.values[f.name];
    if (v == null || v == '') return '';
    return switch (f.type) {
      'date' => showDate('$v', today),
      'bool' => v == true ? 'ja' : 'nej',
      'link' => () {
        final target = collection(f.link ?? '');
        final x = target == null ? null : find(target.name, '$v');
        return x == null ? '$v' : x.str(target!.titleField);
      }(),
      _ => '$v',
    };
  }

  /// Poster i [child] som kopplar till [r].
  List<Rec> children(Collection parent, Rec r, Collection child) {
    final links = child.fields.where((f) => f.type == 'link' && f.link == parent.name).toList();
    final out = [
      for (final x in of(child.name))
        if (links.any((f) => x.str(f.name) == r.id)) x,
    ];
    out.sort((a, b) => _byDateOrTitle(child, a, b));
    return out;
  }
}

int _byDateOrTitle(Collection c, Rec a, Rec b) {
  final d = c.dateField;
  if (d != null) {
    final x = a.str(d.name).compareTo(b.str(d.name));
    if (x != 0) return x;
  }
  return a.str(c.titleField).toLowerCase().compareTo(b.str(c.titleField).toLowerCase());
}

/// Skriver rapporten. [from] är sökvägen rapporten hamnar på, så att länkarna till postfilerna blir rätt.
Future<String> renderReport(Report rep, ReportData data, {String? from}) async {
  final dir = from ?? rep.output;
  final up = '../' * (dir.split('/').length - 1);
  final items = await runQuery(rep.query, data.collections, load: (c) async => data.of(c), now: data.today);

  String group((Collection, Rec) it) {
    final g = rep.group!;
    final (c, r) = it;
    if (g == 'date:week' || g == 'date:month') {
      final d = DateTime.tryParse(c.dateField == null ? '' : r.str(c.dateField!.name));
      if (d == null) return 'Utan datum';
      return g == 'date:week'
          ? 'Vecka ${_isoWeek(d)}${d.year != data.today.year ? ', ${d.year}' : ''}'
          : '${_monthsLong[d.month - 1][0].toUpperCase()}${_monthsLong[d.month - 1].substring(1)} ${d.year}';
    }
    final f = c.fields.where((f) => f.name == g).firstOrNull;
    final v = f == null ? r.str(g) : data.show(c, f, r);
    return v.isEmpty ? '(tomt)' : v;
  }

  String value(String name, Collection? c, Rec? r) {
    switch (name) {
      case 'today':
        return showDate(isoDay(data.today), data.today);
      case 'count':
        return '${items.length}';
      case 'label':
        return rep.label;
    }
    if (c == null || r == null) return '';
    switch (name) {
      case '@title':
        return r.str(c.titleField);
      case '@link':
        return _href('$up${c.name}/${r.id}.yaml');
      case '@collection':
        return c.label;
      case '@id':
        return r.id;
    }
    final f = c.fields.where((f) => f.name == name).firstOrNull;
    return f == null ? r.str(name) : data.show(c, f, r);
  }

  final out = StringBuffer();
  void walk(List<_Node> nodes, Collection? c, Rec? r) {
    for (final n in nodes) {
      switch (n) {
        case _Text(:final text):
          out.write(text);
        case _Var(:final name):
          out.write(value(name, c, r));
        case _Section(kind: 'each', :final children):
          String? last;
          for (final it in items) {
            if (rep.group != null) {
              final g = group(it);
              if (g != last) {
                out.write('\n## $g\n\n');
                last = g;
              }
            }
            walk(children, it.$1, it.$2);
          }
        case _Section(kind: 'children', :final arg, :final children):
          final child = data.collection(arg);
          if (c == null || r == null || child == null) break;
          for (final x in data.children(c, r, child)) {
            walk(children, child, x);
          }
        case _Section(:final kind, :final arg, :final children):
          // if / unless
          final v = value(arg, c, r);
          final has = v.isNotEmpty && v != 'nej';
          if (has == (kind == 'if')) walk(children, c, r);
      }
    }
  }

  walk(_parse(rep.body), null, null);
  // Block-taggar på egna rader lämnar tomma rader; högst en tom rad i rad.
  // Rubriker får alltid luft omkring sig, och högst en tom rad i rad.
  final md = out
      .toString()
      .replaceAllMapped(RegExp(r'\n(#{1,6} [^\n]*)\n(?!\n)'), (m) => '\n\n${m[1]}\n\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return '$generatedMark\n$md\n';
}

String isoDay(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ---------------------------------------------------------------- översikter

/// Översikten för en samling: `<samling>/README.md`.
String collectionOverview(Collection c, ReportData data, List<(Collection, Field)> childLinks) {
  final recs = [...data.of(c.name)];
  final date = c.dateField, time = c.timeField;
  final others = [
    for (final f in c.fields)
      if (f.name != c.titleField && f != date && f != time) f,
  ].take(3).toList();
  final cols = [
    ?date,
    ?time,
    c.fields.firstWhere(
      (f) => f.name == c.titleField,
      orElse: () => Field(name: c.titleField, type: 'text'),
    ),
    ...others,
  ];

  String cell(Field f, Rec r) {
    if (f.name == c.titleField) {
      return '[${_esc(r.str(f.name).isEmpty ? r.id : r.str(f.name))}](${_href('${r.id}.yaml')})';
    }
    var s = data.show(c, f, r);
    if (f.type == 'link' && s.isNotEmpty) s = '[${_esc(s)}](${_href('../${f.link}/${r.str(f.name)}.yaml')})';
    if (f.type == 'longtext' && s.length > 80) s = '${s.substring(0, 77)}…';
    return f.type == 'link' ? s : _esc(s);
  }

  String table(List<Rec> rows) => [
    '| ${cols.map((f) => _esc(f.label)).join(' | ')} |',
    '|${cols.map((_) => '---').join('|')}|',
    for (final r in rows) '| ${cols.map((f) => cell(f, r)).join(' | ')} |',
  ].join('\n');

  final out = StringBuffer()
    ..writeln(generatedMark)
    ..writeln('# ${c.label}')
    ..writeln()
    ..writeln(
      '${recs.length} ${recs.length == 1 ? 'post' : 'poster'} · uppdaterad ${isoDay(data.today)} · [alla samlingar](../README.md)',
    )
    ..writeln();
  if (recs.isEmpty) {
    out.writeln('Inga poster än.');
  } else if (date != null) {
    final t = isoDay(data.today);
    final coming = recs.where((r) => r.str(date.name).compareTo(t) >= 0).toList()
      ..sort((a, b) => _byDateOrTitle(c, a, b));
    final past = recs.where((r) => r.str(date.name).compareTo(t) < 0).toList()..sort((a, b) => _byDateOrTitle(c, b, a));
    if (coming.isNotEmpty) {
      out
        ..writeln('## Kommande')
        ..writeln()
        ..writeln(table(coming))
        ..writeln();
    }
    if (past.isNotEmpty) {
      out
        ..writeln('## Tidigare')
        ..writeln()
        ..writeln(table(past))
        ..writeln();
    }
  } else {
    recs.sort((a, b) => _byDateOrTitle(c, a, b));
    out
      ..writeln(table(recs))
      ..writeln();
  }
  // Underposter under sin förälder.
  for (final (child, _) in childLinks) {
    final groups = [
      for (final r in (recs..sort((a, b) => _byDateOrTitle(c, a, b))))
        if (data.children(c, r, child).isNotEmpty) (r, data.children(c, r, child)),
    ];
    if (groups.isEmpty) continue;
    out
      ..writeln('## ${child.label}')
      ..writeln();
    for (final (r, kids) in groups) {
      out.writeln('### [${_esc(r.str(c.titleField))}](${_href('${r.id}.yaml')})');
      out.writeln();
      for (final k in kids) {
        final d = child.dateField == null ? '' : data.show(child, child.dateField!, k);
        final rest = [
          for (final f in child.fields)
            if (f.name != child.titleField && f != child.dateField && !(f.type == 'link' && f.link == c.name))
              if (data.show(child, f, k).isNotEmpty) data.show(child, f, k),
        ].take(2).map(_esc).join(' · ');
        out.writeln(
          '- ${d.isEmpty ? '' : '$d: '}[${_esc(k.str(child.titleField))}](${_href('../${child.name}/${k.id}.yaml')})'
          '${rest.isEmpty ? '' : ' – $rest'}',
        );
      }
      out.writeln();
    }
  }
  return '${out.toString().trim()}\n';
}

/// Översikten i roten: `README.md` med alla samlingar och rapporter.
String rootOverview(ReportData data, List<Report> reports) {
  final t = isoDay(data.today);
  final out = StringBuffer()
    ..writeln(generatedMark)
    ..writeln('# Mina poster')
    ..writeln()
    ..writeln('Uppdaterad $t av alt. Varje post är en egen fil i samlingens mapp.')
    ..writeln()
    ..writeln('## Samlingar')
    ..writeln()
    ..writeln('| Samling | Poster | Nästa |')
    ..writeln('|---|---|---|');
  for (final c in [...data.collections]..sort((a, b) => a.label.compareTo(b.label))) {
    if (c.encrypted) {
      out.writeln('| ${_esc(c.label)} (krypterad) | – | – |');
      continue;
    }
    final recs = data.of(c.name);
    var next = '';
    final d = c.dateField;
    if (d != null) {
      final coming = recs.where((r) => r.str(d.name).compareTo(t) >= 0).toList()
        ..sort((a, b) => _byDateOrTitle(c, a, b));
      if (coming.isNotEmpty) {
        next = '${showDate(coming.first.str(d.name), data.today)}: ${_esc(coming.first.str(c.titleField))}';
      }
    }
    out.writeln('| [${_esc(c.label)}](${_href(c.name)}/) | ${recs.length} | $next |');
  }
  if (reports.isNotEmpty) {
    out
      ..writeln()
      ..writeln('## Rapporter')
      ..writeln();
    for (final r in reports) {
      out.writeln('- [${_esc(r.label)}](${_href(r.output)})');
    }
  }
  return '${out.toString().trim()}\n';
}

/// Alla filer som rapporterna ska ha i datarepot: sökväg → innehåll.
/// Krypterade samlingar får ingen översikt och ingår inte i rapporterna.
Future<Map<String, String>> buildReports(Workspace ws, ReportData all) async {
  final open = [
    for (final c in all.collections)
      if (!c.encrypted) c,
  ];
  final data = ReportData(open, {for (final c in open) c.name: all.of(c.name)}, all.today);
  final files = <String, String>{};
  files['README.md'] = rootOverview(ReportData(all.collections, data.records, all.today), ws.reports);
  for (final c in open) {
    final kids = [
      for (final x in open)
        for (final f in x.fields)
          if (f.type == 'link' && f.link == c.name) (x, f),
    ];
    files['${c.name}/README.md'] = collectionOverview(c, data, kids);
  }
  for (final r in ws.reports) {
    try {
      files[r.output] = await renderReport(r, data);
    } catch (e) {
      files[r.output] = '$generatedMark\n# ${r.label}\n\nRapporten gick inte att skriva: $e\n';
    }
  }
  return files;
}
