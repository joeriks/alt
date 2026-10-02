import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';
import 'package:yaml/yaml.dart';

/// Ett recept: YAML-huvud mellan `---`-rader, sedan JavaScript med `function run(ctx)`.
class Recipe {
  Recipe({required this.name, required this.header, required this.js});

  final String name;
  final Map<String, dynamic> header;
  final String js;

  String get label => header['label']?.toString() ?? name;

  List<Map<String, dynamic>> get triggers => [
    for (final t in (header['triggers'] as List? ?? const []))
      if (t is Map) Map<String, dynamic>.from(t),
  ];

  static Recipe parse(String source) {
    final lines = const LineSplitter().convert(source);
    if (lines.isEmpty || lines.first.trim() != '---') {
      throw const FormatException('Receptet måste börja med ---');
    }
    final end = lines.indexWhere((l) => l.trim() == '---', 1);
    if (end < 0) throw const FormatException('YAML-huvudet saknar avslutande ---');
    final yaml = loadYaml(lines.sublist(1, end).join('\n'));
    final header = jsonDecode(jsonEncode(yaml)) as Map<String, dynamic>;
    final name = header['name']?.toString();
    if (name == null || !RegExp(r'^[a-zåäö][a-zåäö0-9_]*$').hasMatch(name)) {
      throw FormatException('Ogiltigt namn: $name');
    }
    return Recipe(name: name, header: header, js: lines.sublist(end + 1).join('\n'));
  }
}

class Output {
  Output(this.kind, this.title, this.body);
  final String kind;
  final String title;
  final String body;
}

class RunResult {
  RunResult({
    required this.recipe,
    required this.trigger,
    required this.started,
    required this.ms,
    this.outputs = const [],
    this.logs = const [],
    this.error,
  });

  final String recipe;
  final String trigger;
  final DateTime started;
  final int ms;
  final List<Output> outputs;
  final List<String> logs;
  final String? error;

  bool get ok => error == null;

  Map<String, dynamic> toJson() => {
    'recipe': recipe,
    'trigger': trigger,
    'started': started.toIso8601String(),
    'ms': ms,
    'ok': ok,
    'outputs': [
      for (final o in outputs) {'kind': o.kind, 'title': o.title, 'body': o.body},
    ],
    'logs': logs,
    if (error != null) 'error': error,
  };
}

/// Kör ett recept i en ny QuickJS-runtime. Receptet får bara det som skickas in
/// här: signal, inputs, store, out och log. Inget nätverk, inga filer.
RunResult runRecipe(Recipe recipe, {required String trigger, required Directory storeDir}) {
  final started = DateTime.now();
  final watch = Stopwatch()..start();

  final storeFile = File('${storeDir.path}/${recipe.name}.json');
  final store = storeFile.existsSync() ? storeFile.readAsStringSync() : '{}';
  final signal = jsonEncode({'trigger': trigger, 'at': started.toIso8601String()});

  final code =
      '''
var __out = [], __logs = [], __store = $store;
var __ctx = {
  signal: $signal,
  inputs: {},
  store: {
    get: function (k) { return __store[k]; },
    set: function (k, v) { __store[k] = v; }
  },
  out: {
    show: function (title, body) {
      __out.push({ kind: 'show', title: String(title), body: body == null ? '' : String(body) });
    }
  },
  log: function (m) { __logs.push(String(m)); }
};
${recipe.js}
;JSON.stringify((function () {
  try {
    if (typeof run !== 'function') throw new Error('Receptet saknar function run(ctx)');
    run(__ctx);
    return { out: __out, logs: __logs, store: __store };
  } catch (e) {
    return { error: String(e) + (e && e.stack ? '\\n' + e.stack : ''), logs: __logs };
  }
})());
''';

  final runtime = getJavascriptRuntime(xhr: false);
  try {
    final res = runtime.evaluate(code);
    if (res.isError) {
      return RunResult(
        recipe: recipe.name,
        trigger: trigger,
        started: started,
        ms: watch.elapsedMilliseconds,
        error: res.stringResult,
      );
    }
    final data = jsonDecode(res.stringResult) as Map<String, dynamic>;
    final logs = [for (final l in (data['logs'] as List? ?? const [])) l.toString()];
    if (data['error'] != null) {
      return RunResult(
        recipe: recipe.name,
        trigger: trigger,
        started: started,
        ms: watch.elapsedMilliseconds,
        logs: logs,
        error: data['error'].toString(),
      );
    }
    storeDir.createSync(recursive: true);
    storeFile.writeAsStringSync(jsonEncode(data['store']));
    return RunResult(
      recipe: recipe.name,
      trigger: trigger,
      started: started,
      ms: watch.elapsedMilliseconds,
      logs: logs,
      outputs: [
        for (final o in (data['out'] as List? ?? const []))
          Output(o['kind'].toString(), o['title'].toString(), o['body'].toString()),
      ],
    );
  } catch (e) {
    return RunResult(
      recipe: recipe.name,
      trigger: trigger,
      started: started,
      ms: watch.elapsedMilliseconds,
      error: e.toString(),
    );
  } finally {
    runtime.dispose();
  }
}

/// Tolkar `every: 15m` / `2h` / `1d`. Android tillåter inte kortare än 1 minut.
Duration? parseEvery(String? s) {
  final m = RegExp(r'^(\d+)\s*([mhd])$').firstMatch(s?.trim() ?? '');
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  return switch (m.group(2)) {
    'm' => Duration(minutes: n),
    'h' => Duration(hours: n),
    _ => Duration(days: n),
  };
}
