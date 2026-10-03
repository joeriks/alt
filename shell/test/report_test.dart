import 'package:alt/records.dart';
import 'package:alt/report.dart';
import 'package:alt/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

final _files = {
  'apps/mb/app.yaml': 'label: Memory bank\n',
  'apps/mb/areas.collection.yaml':
      'label: Areas\ntitle: header\nfields:\n  header: { text, required, label: Header }\n'
      '  description: { text, label: Description }\n',
  'apps/mb/sub_areas.collection.yaml':
      'label: Sub-areas\nfields:\n  title: { text, required, label: Title }\n'
      '  description: { text, label: Description }\n  parent: { link: areas, required, label: Area }\n',
  'apps/mb/calendar.collection.yaml':
      'label: Calendar\nfields:\n  date: { date, required, label: Date }\n  title: { text, required, label: Title }\n'
      '  done: { bool, label: Done }\n',
  'apps/mb/areas.report.md': '''---
label: Areas
from: areas
sort: header
---
# Ansvarsområden ({{count}})

{{#each}}
## [{{header}}]({{@link}})
{{#if description}}
{{description}}
{{/if}}

{{#children sub_areas}}
- {{title}}{{#if description}}: {{description}}{{/if}}
{{/children}}
{{/each}}
''',
  'apps/mb/weeks.report.md': '''---
label: Coming weeks
from: calendar
where: { date: { from: today } }
group: date:week
---
{{#each}}
- {{date}} {{title}}{{#if done}} ✓{{/if}}
{{/each}}
''',
};

void main() {
  final ws = Workspace.fromFiles(_files);
  final today = DateTime(2026, 10, 3);
  final data = ReportData(ws.collections, {
    'areas': [
      Rec('areas', 'huset', {'header': 'Huset', 'description': 'Underhåll'}),
      Rec('areas', 'bilen', {'header': 'Bilen'}),
    ],
    'sub_areas': [
      Rec('sub_areas', 'tak', {'title': 'Taket', 'description': 'Rensa hängrännor', 'parent': 'huset'}),
      Rec('sub_areas', 'värme', {'title': 'Värmepumpen', 'parent': 'huset'}),
      Rec('sub_areas', 'däck', {'title': 'Däckbyte', 'parent': 'bilen'}),
    ],
    'calendar': [
      Rec('calendar', 'a', {'date': '2026-10-05', 'title': 'Tandläkare'}),
      Rec('calendar', 'b', {'date': '2026-10-14', 'title': 'Besiktning', 'done': true}),
      Rec('calendar', 'c', {'date': '2026-09-01', 'title': 'Gammalt'}),
    ],
  }, today);

  test('rapporter läses in utan fel', () {
    expect(ws.problems, isEmpty);
    expect(ws.reports.map((r) => r.label), ['Areas', 'Coming weeks']);
  });

  test('mall med underposter', () async {
    final md = await renderReport(ws.reports.first, data);
    expect(md, startsWith(generatedMark));
    expect(md, contains('# Ansvarsområden (2)'));
    expect(md, contains('## [Bilen](../areas/bilen.yaml)\n\n- Däckbyte'));
    expect(md, contains('- Taket: Rensa hängrännor\n- Värmepumpen\n'));
    expect(md.indexOf('Bilen'), lessThan(md.indexOf('Huset')));
  });

  test('gruppering per vecka', () async {
    final md = await renderReport(ws.reports.last, data);
    expect(md, contains('## Vecka 41\n\n- mån 5 okt Tandläkare'));
    expect(md, contains('## Vecka 42\n\n- ons 14 okt Besiktning ✓'));
    expect(md, isNot(contains('Gammalt')));
  });

  test('översikter', () async {
    final files = await buildReports(ws, data);
    expect(files.keys, containsAll(['README.md', 'areas/README.md', '_reports/areas.md', '_reports/weeks.md']));
    expect(files['areas/README.md'], contains('### [Huset](huset.yaml)'));
    expect(files['areas/README.md'], contains('- [Taket](../sub_areas/tak.yaml) – Rensa hängrännor'));
    expect(files['sub_areas/README.md'], contains('[Huset](../areas/huset.yaml)'));
    expect(files['calendar/README.md'], contains('## Kommande'));
    expect(files['README.md'], contains('| [Calendar](calendar/) | 3 | mån 5 okt: Tandläkare |'));
    expect(files['README.md'], contains('- [Coming weeks](_reports/weeks.md)'));
  });

  test('fel i mallen rapporteras', () {
    final bad = Workspace.fromFiles({..._files, 'apps/mb/bad.report.md': '---\nfrom: areas\n---\n{{#each}}x\n'});
    expect(bad.problems.single, contains('slutar aldrig'));
  });
}
