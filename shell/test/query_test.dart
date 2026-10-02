import 'package:alt/query.dart';
import 'package:alt/records.dart';
import 'package:alt/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 2, 15);
  final ws = Workspace.fromFiles({
    'types/dated_entry.type.yaml':
        'role: timeline\ntitle: title\nfields:\n  date: { date, required }\n  title: { text, required }\n',
    'apps/mb/app.yaml': 'label: Memory bank',
    'apps/mb/tasks.collection.yaml': 'type: dated_entry\nfields:\n  done: { bool }\n',
    'apps/mb/private.collection.yaml': 'type: dated_entry\n',
    'apps/mb/open.query.yaml':
        'label: Open tasks\nfrom: tasks\nwhere:\n  done: false\n  date: { to: today+7d }\nsort: date\n',
    'apps/mb/week.query.yaml':
        'label: Week\nfrom: { type: dated_entry }\nwhere:\n  date: { from: today, to: today+1w }\n',
  });
  final data = {
    'tasks': [
      Rec('tasks', 'a', {'date': '2026-10-05', 'title': 'Deklarera'}),
      Rec('tasks', 'b', {'date': '2026-10-03', 'title': 'Klar redan', 'done': true}),
      Rec('tasks', 'c', {'date': '2026-11-20', 'title': 'Långt bort'}),
      Rec('tasks', 'd', {'date': '2026-09-30', 'title': 'Försenad', 'done': false}),
    ],
    'private': [
      Rec('private', 'e', {'date': '2026-10-04', 'title': 'Middag'}),
    ],
  };
  Future<List<Rec>> load(String c) async => data[c] ?? [];

  test('frågor läses in och visas i menyn', () {
    expect(ws.problems, isEmpty);
    expect(ws.queries.map((q) => q.label), ['Open tasks', 'Week']);
    expect(ws.queries.first.appLabel, 'Memory bank');
  });

  test('ej klara uppgifter, sorterade på datum', () async {
    final r = await runQuery(ws.queries.first, ws.collections, load: load, now: now);
    expect(r.map((x) => x.$2.str('title')), ['Försenad', 'Deklarera']);
  });

  test('alla samlingar av en typ, kommande vecka', () async {
    final r = await runQuery(ws.queries.last, ws.collections, load: load, now: now);
    expect(r.map((x) => x.$2.str('title')), ['Klar redan', 'Middag', 'Deklarera']);
  });

  test('relativa datum', () {
    expect(relativeDate('today', now), DateTime(2026, 10, 2));
    expect(relativeDate('today+30d', now), DateTime(2026, 11, 1));
    expect(relativeDate('today-1w', now), DateTime(2026, 9, 25));
    expect(relativeDate('imorgon', now), isNull);
  });

  test('fel i frågan rapporteras', () {
    final bad = Workspace.fromFiles({
      'apps/mb/x.query.yaml': 'from: finns_inte\n',
      'apps/mb/y.query.yaml': 'from: x\nwhere:\n  date: { before: today }\n',
    });
    expect(bad.problems, hasLength(2));
  });
}
