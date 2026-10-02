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

  test('encrypted är sant om det inte anges', () {
    final c = Collection.parse('x', 'a', 'A', 'fields:\n  namn: { text }\n');
    expect(c.encrypted, true);
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
}
