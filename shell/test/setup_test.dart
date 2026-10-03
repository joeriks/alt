import 'package:alt/setup.dart';
import 'package:flutter_test/flutter_test.dart';

GitHubGet fake(Map<String, (int, dynamic)> answers) =>
    (method, path, [body]) async => answers['$method $path'] ?? (404, null);

void main() {
  test('allt i ordning', () async {
    final checks = await checkGitHub(
      fake({
        'GET /user': (200, {'login': 'joeriks'}),
        'GET /repos/j/r': (200, {'private': true}),
        'POST /repos/j/r/git/blobs': (201, {}),
        'GET /repos/j/d': (200, {'private': true}),
        'POST /repos/j/d/git/blobs': (201, {}),
      }),
      'j/r',
      'j/d',
    );
    expect(checks.every((c) => c.ok), isTrue);
    expect(checks.first.label, contains('joeriks'));
  });

  test('fel nyckel, saknat repo, publikt datarepo och bara läsrätt förklaras', () async {
    expect((await checkGitHub(fake({'GET /user': (401, null)}), 'j/r', 'j/d')).single.ok, isFalse);
    final checks = await checkGitHub(
      fake({
        'GET /user': (200, {'login': 'joeriks'}),
        'GET /repos/j/d': (200, {'private': false}),
        'POST /repos/j/d/git/blobs': (403, null),
      }),
      'j/r',
      'j/d',
    );
    final bad = [
      for (final c in checks)
        if (!c.ok) c.label,
    ];
    expect(bad, ['Receptrepot: j/r', 'Datarepot är publikt', 'Datarepot: nyckeln får inte skriva']);
    expect(checks.firstWhere((c) => c.label == 'Receptrepot: j/r').fix, contains('Repository access'));
  });

  test('ett tomt repo är okej', () async {
    final checks = await checkGitHub(
      fake({
        'GET /user': (200, {'login': 'joeriks'}),
        'GET /repos/j/r': (200, {'private': true}),
        'POST /repos/j/r/git/blobs': (409, null),
        'GET /repos/j/d': (200, {'private': true}),
        'POST /repos/j/d/git/blobs': (409, null),
      }),
      'j/r',
      'j/d',
    );
    expect(checks.every((c) => c.ok), isTrue);
  });
}
