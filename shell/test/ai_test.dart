import 'dart:convert';

import 'package:alt/ai.dart';
import 'package:alt/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> reply(Object data, {String stop = 'end_turn'}) => {
  'stop_reason': stop,
  'content': [
    {'type': 'text', 'text': jsonEncode(data)},
  ],
};

void main() {
  test('förfrågan skickar bara filerna och ändringen', () {
    final r = buildRequest('lägg till böcker', {'apps/a/app.yaml': 'label: A'});
    expect(r['model'], 'claude-haiku-4-5');
    expect(r['output_config']['format']['type'], 'json_schema');
    final msg = r['messages'][0]['content'] as String;
    expect(msg, contains('<file path="apps/a/app.yaml">'));
    expect(msg, contains('lägg till böcker'));
  });

  test('svaret tolkas till filer', () {
    final p = parseResponse(
      reply({
        'summary': 'La till böcker',
        'files': [
          {'path': 'apps/memory_bank/books.collection.yaml', 'content': 'x'},
          {'path': 'lang/sv.yaml', 'content': 'y'},
        ],
      }),
    );
    expect(p.summary, 'La till böcker');
    expect(p.files.map((f) => f.path), ['apps/memory_bank/books.collection.yaml', 'lang/sv.yaml']);
  });

  test('filer utanför receptmapparna avvisas', () {
    for (final bad in ['data/x/y.yaml', '../etc', 'apps/a/../../x', '.github/workflows/x.yml']) {
      expect(
        () => parseResponse(
          reply({
            'summary': '',
            'files': [
              {'path': bad, 'content': ''},
            ],
          }),
        ),
        throwsA(isA<AiException>()),
        reason: bad,
      );
    }
  });

  test('avböjt och avkortat svar ger tydliga fel', () {
    expect(() => parseResponse({'stop_reason': 'refusal', 'content': []}), throwsA(isA<AiException>()));
    expect(() => parseResponse(reply({}, stop: 'max_tokens')), throwsA(isA<AiException>()));
  });

  test('kostnaden räknas i öre', () {
    // Haiku, 2000 in och 600 ut: (2000 * 1 + 600 * 5) / 1e6 USD = 0,005 USD = 5 öre
    expect(costOre('claude-haiku-4-5', 2000, 600), closeTo(5, 0.001));
    expect(costOre('okänd', 2000, 600), isNull);
  });

  test('OpenAI: förfrågan och svar', () {
    final r = buildOpenAiRequest('lägg till böcker', {'lang/sv.yaml': 'apps: {}'});
    expect(r['response_format']['json_schema']['strict'], true);
    expect(r['messages'][1]['content'], contains('lägg till böcker'));
    final p = parseOpenAiResponse({
      'choices': [
        {
          'finish_reason': 'stop',
          'message': {
            'content': jsonEncode({
              'summary': 'ok',
              'files': [
                {'path': 'lang/sv.yaml', 'content': 'x'},
              ],
            }),
          },
        },
      ],
      'usage': {'prompt_tokens': 2000, 'completion_tokens': 800},
    });
    expect(p.files.single.path, 'lang/sv.yaml');
    expect(p.ore, closeTo(1.4, 0.001));
    expect(
      () => parseOpenAiResponse({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': null, 'refusal': 'nej'},
          },
        ],
      }),
      throwsA(isA<AiException>()),
    );
    expect(
      () => parseOpenAiResponse({
        'choices': [
          {
            'finish_reason': 'length',
            'message': {'content': '{'},
          },
        ],
      }),
      throwsA(isA<AiException>()),
    );
  });

  test('raddiff', () {
    expect(lineDiff('a\nb\nc\n', 'a\nB\nc\n'), ['  a', '- b', '+ B', '  c']);
    expect(lineDiff('', 'ny\n'), ['+ ny']);
  });

  test('utkast kan lägga till nya filer', () {
    final ws = Workspace.fromFiles({
      'apps/mb/app.yaml': 'label: Memory bank',
      'apps/mb/books.collection.yaml': 'label: Books\nfields:\n  title: { text, required }\n',
    });
    expect(ws.problems, isEmpty);
    expect(ws.collections.single.appLabel, 'Memory bank');
    expect(ws.collections.single.label, 'Books');
  });
}
