import 'package:alt/main.dart';
import 'package:alt/records.dart';
import 'package:alt/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('samlingsfilen tolkas', () {
    final c = Collection.parse('privat_kalender', 'minnesbank', 'Minnesbank', '''
label: Privat kalender
role: timeline
encrypted: true
title: titel
fields:
  datum:      { date, required }
  tid:        { time }
  titel:      { text, required }
  anteckning: { longtext }
  vem:        { link: person }
''');
    expect(c.label, 'Privat kalender');
    expect(c.role, 'timeline');
    expect(c.encrypted, true);
    expect(c.dateField!.name, 'datum');
    expect(c.timeField!.name, 'tid');
    expect(c.fields.map((f) => '${f.name}:${f.type}:${f.required}'), [
      'datum:date:true',
      'tid:time:false',
      'titel:text:true',
      'anteckning:longtext:false',
      'vem:link:false',
    ]);
    expect(c.fields.last.link, 'person');
  });

  test('encrypted är falskt om det inte anges (repot är privat)', () {
    final c = Collection.parse('x', 'a', 'A', 'fields:\n  namn: { text }\n');
    expect(c.encrypted, false);
    expect(c.titleField, 'namn');
  });

  test('id följer namnreglerna', () {
    expect(slug('Mammas födelsedag! 2026-10-11'), 'mammas_födelsedag_2026_10_11');
    expect(slug('2026 bokslut'), 'p_2026_bokslut');
    expect(slug('Åka till Öland'), 'åka_till_öland');
    expect(slug('   '), 'post');
  });

  test('samlingar delar en typ och får lägga till fält', () {
    final types = {
      'datumpost': {
        'role': 'timeline',
        'title': 'titel',
        'fields': {
          'datum': {'date': null, 'required': null},
          'titel': {'text': null},
        },
      },
    };
    final jobb = Collection.parse(
      'jobb_kalender',
      'minnesbank',
      'Minnesbank',
      'type: datumpost\nlabel: Jobb\nencrypted: false\nfields:\n  projekt: { text }\n',
      types: types,
    );
    expect(jobb.role, 'timeline');
    expect(jobb.encrypted, false);
    expect(jobb.fields.map((f) => f.name), ['datum', 'titel', 'projekt']);
    expect(
      () => Collection.parse('x', 'a', 'A', 'type: datumpost\nfields:\n  datum: { text }\n', types: types),
      throwsFormatException,
    );
    expect(() => Collection.parse('x', 'a', 'A', 'type: saknas\n', types: types), throwsFormatException);
  });

  test('fält har engelskt namn och svensk etikett', () {
    final c = Collection.parse(
      'x',
      'a',
      'A',
      'fields:\n  date: { date, required, label: Datum }\n  note: { longtext }\n',
    );
    expect(c.fields.first.name, 'date');
    expect(c.fields.first.label, 'Datum');
    expect(c.fields.first.required, true);
    expect(c.fields.last.label, 'note');
  });

  test('svensk språkfil ersätter engelska etiketter', () {
    final types = {
      'dated_entry': {
        'fields': {
          'date': {'date': null, 'label': 'Date'},
          'title': {'text': null, 'label': 'Title'},
        },
      },
    };
    final lang = {
      'apps': {'memory_bank': 'Minnesbank'},
      'types': {
        'dated_entry': {
          'fields': {'date': 'Datum'},
        },
      },
      'collections': {
        'work_calendar': {
          'label': 'Jobbkalender',
          'fields': {'project': 'Projekt'},
        },
      },
    };
    final c = Collection.parse(
      'work_calendar',
      'memory_bank',
      'Memory bank',
      'type: dated_entry\nlabel: Work calendar\nfields:\n  project: { text, label: Project }\n',
      types: types,
      lang: lang,
    );
    expect(c.appLabel, 'Minnesbank');
    expect(c.label, 'Jobbkalender');
    expect(c.fields.map((f) => f.label), ['Datum', 'Title', 'Projekt']);
    expect(c.fields.map((f) => f.name), ['date', 'title', 'project']);
  });

  test('menyn visar en nivå i taget, med undermenyer', () {
    final labels = [
      'Datum / 14 dagar',
      'Minnesbank / Privat kalender',
      'Minnesbank / Jobbkalender',
      'Spike / Hej',
      'Ensam',
    ];
    // Datum har bara ett val och visas därför direkt; Spike likaså.
    expect(menuLevel(labels, []), [('Datum / 14 dagar', 0), ('Minnesbank', null), ('Spike / Hej', 3), ('Ensam', 4)]);
    expect(menuLevel(labels, ['Minnesbank']), [('Privat kalender', 1), ('Jobbkalender', 2)]);
    expect(menuLevel(labels, ['Okänd']), isEmpty);
  });

  test('en koppling till en samling som inte finns rapporteras', () {
    final ws = Workspace.fromFiles({
      'apps/mb/app.yaml': 'label: MB\n',
      'apps/mb/areas.collection.yaml': 'title: header\nfields:\n  header: { text, required }\n',
      'apps/mb/sub_areas.collection.yaml': 'fields:\n  title: { text }\n  parent: { link: areas, required }\n',
      'apps/mb/logs.collection.yaml': 'fields:\n  title: { text }\n  area: { link: under_areas }\n',
    });
    expect(ws.problems.single, contains('under_areas'));
    expect(ws.collection('sub_areas')!.fields.firstWhere((f) => f.name == 'parent').link, 'areas');
  });
}
