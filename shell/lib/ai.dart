import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'workspace.dart';

/// AI-styrning: du beskriver en ändring med egna ord, Claude skriver om filerna
/// i receptrepot, och resultatet blir utkast som du provar innan något sparas.
///
/// Det enda som skickas är filerna från receptrepot (apps/, types/, lang/) och
/// dina utkast. Poster, körlogg och lagrade värden skickas aldrig.

const _secure = FlutterSecureStorage();

/// Haiku är billigast: en vanlig ändring kostar några öre.
const model = 'claude-haiku-4-5';

/// Pris i USD per miljon token (in, ut) och en ungefärlig växelkurs, för att visa kostnaden.
const _usdPerMTokIn = 1.0, _usdPerMTokOut = 5.0, _sekPerUsd = 10.0;

Future<String?> claudeKey() => _secure.read(key: 'anthropic_key');
Future<void> setClaudeKey(String key) => _secure.write(key: 'anthropic_key', value: key.trim());

const aiRules = '''
Du ändrar filerna i en persons receptrepo för appen alt, en Android-app där användaren bygger egna små appar utan att bygga om appen.
Svara med de filer som ska ändras eller skapas, med HELA det nya innehållet i varje fil, och en kort sammanfattning på svenska av vad du ändrade.
Ändra bara det som behövs för att göra det användaren ber om. Rör inte andra filer.

Filer och format:
- apps/<app>/app.yaml: `label: <engelsk etikett>`.
- apps/<app>/<name>.collection.yaml: en samling (som en tabell). Nycklar: label, type (valfri, en typ från types/), role (valfri: timeline gör att samlingen syns i datumvyn), encrypted (true som standard), title (vilket fält som är postens titel), fields.
- Fält skrivs `name: { <typ>, required, label: <Engelsk etikett> }`. Typer: text, longtext, date, time, number, bool, link (som `{ link: <samling> }`). required är valfritt.
- types/<name>.type.yaml: delad struktur med role, title och fields. En samling med `type: <name>` får typens fält och får lägga till egna fält, men inte ändra typens.
- lang/sv.yaml: svenska etiketter som ersätter de engelska. Avsnitt: `apps: { <app>: <etikett> }`, `types: { <typ>: { fields: { <fält>: <etikett> } } }`, `collections: { <samling>: { label: <etikett>, fields: { <fält>: <etikett> } } }`.
- apps/<app>/<name>.recipe: ett recept. Först ett YAML-huvud mellan två rader med `---`, med name, label och triggers. Sedan JavaScript med `function run(ctx) { ... }`.
  - triggers är en lista: `- menu: Sökväg/Namn` (menyval), `- every: 15m` (även 2h, 1d).
  - ctx har: signal.trigger ('menu', 'every' eller 'prova'), signal.at (ISO-tid), store.get(nyckel) / store.set(nyckel, värde) för receptets egna sparade värden, out.show(titel, text) som visar en notis, och log(text).
  - JavaScript körs i QuickJS: inget nätverk, inga filer, ingen Intl. Skriv ES2020 utan moduler.

Regler:
- Tekniska namn (appar, samlingar, typer, fält, recept) skrivs på engelska med gemener a-z, siffror och understreck, och börjar med en bokstav. Till exempel private_calendar och dated_entry.
- Etiketter (label) skrivs på engelska. Lägg ALLTID till svenska etiketter för allt nytt i lang/sv.yaml, och behåll det som redan finns där.
- Byt aldrig namn på en befintlig samling eller ett befintligt fält om användaren inte ber om det. Posterna är kopplade till namnen.
- Svara bara med filer under apps/, types/ eller lang/.
''';

class AiFile {
  AiFile(this.path, this.content);
  final String path;
  final String content;
}

class AiProposal {
  AiProposal(this.summary, this.files, {this.ore});
  final String summary;
  final List<AiFile> files;

  /// Ungefärlig kostnad i öre, om svaret talade om hur många token det blev.
  final double? ore;
}

/// Kostnad i öre för ett anrop, från svarets usage.
double? costOre(Map<String, dynamic>? usage) {
  if (usage == null) return null;
  final input = (usage['input_tokens'] as num? ?? 0) + (usage['cache_creation_input_tokens'] as num? ?? 0);
  final output = usage['output_tokens'] as num? ?? 0;
  return (input * _usdPerMTokIn + output * _usdPerMTokOut) / 1e6 * _sekPerUsd * 100;
}

class AiException implements Exception {
  AiException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _schema = {
  'type': 'object',
  'properties': {
    'summary': {'type': 'string'},
    'files': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'content': {'type': 'string'},
        },
        'required': ['path', 'content'],
        'additionalProperties': false,
      },
    },
  },
  'required': ['summary', 'files'],
  'additionalProperties': false,
};

/// Bygger förfrågan till Claude. [files] är relativ sökväg → innehåll.
Map<String, dynamic> buildRequest(String ask, Map<String, String> files) {
  final listing = StringBuffer();
  for (final e in (files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) {
    listing.writeln('<file path="${e.key}">\n${e.value}\n</file>');
  }
  return {
    'model': model,
    'max_tokens': 8000,
    'output_config': {
      'format': {'type': 'json_schema', 'schema': _schema},
    },
    'system': aiRules,
    'messages': [
      {'role': 'user', 'content': 'Receptrepots filer just nu:\n\n$listing\nÄndring jag vill ha:\n$ask'},
    ],
  };
}

final _pathRule = RegExp(r'^(apps/[a-zåäö][a-zåäö0-9_]*/[a-zåäö0-9_.]+|types/[a-z0-9_.]+|lang/[a-z]{2}\.yaml)$');

/// Tolkar svaret. Kastar AiException om Claude avböjde, svaret blev avkortat
/// eller innehåller filer utanför apps/, types/ och lang/.
AiProposal parseResponse(Map<String, dynamic> res) {
  final stop = res['stop_reason'];
  if (stop == 'refusal') throw AiException('Claude avböjde förfrågan.');
  if (stop == 'max_tokens') throw AiException('Svaret blev för långt och avbröts. Försök med en mindre ändring.');
  final text = [
    for (final b in (res['content'] as List? ?? const []))
      if (b is Map && b['type'] == 'text') b['text'] as String,
  ].join();
  final Map<String, dynamic> data;
  try {
    data = jsonDecode(text) as Map<String, dynamic>;
  } catch (_) {
    throw AiException('Svaret gick inte att läsa.');
  }
  final files = <AiFile>[];
  for (final f in (data['files'] as List? ?? const [])) {
    final path = (f['path'] as String).trim();
    if (!_pathRule.hasMatch(path) || path.contains('..')) {
      throw AiException('Claude föreslog en fil utanför receptrepots mappar: $path');
    }
    files.add(AiFile(path, f['content'] as String));
  }
  return AiProposal((data['summary'] ?? '').toString(), files, ore: costOre(res['usage'] as Map<String, dynamic>?));
}

/// Skickar ändringen till Claude och returnerar förslaget.
Future<AiProposal> askClaude(String ask, Map<String, String> files) async {
  final key = await claudeKey();
  if (key == null || key.isEmpty) throw AiException('Ingen Claude-nyckel. Lägg in den under System / Claude-nyckel.');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(Uri.parse('https://api.anthropic.com/v1/messages'));
    req.headers.contentType = ContentType.json;
    req.headers.set('x-api-key', key);
    req.headers.set('anthropic-version', '2023-06-01');
    req.add(utf8.encode(jsonEncode(buildRequest(ask, files))));
    final res = await req.close().timeout(const Duration(minutes: 5));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode == 401) throw AiException('Claude-nyckeln godtogs inte.');
    if (res.statusCode == 429) throw AiException('För många förfrågningar just nu. Vänta en stund och försök igen.');
    if (res.statusCode >= 500) {
      throw AiException('Claude svarar inte just nu (${res.statusCode}). Försök igen om en stund.');
    }
    if (res.statusCode != 200) {
      var msg = body;
      try {
        msg = (jsonDecode(body) as Map)['error']['message'].toString();
      } catch (_) {}
      throw AiException('Fel ${res.statusCode}: $msg');
    }
    return parseResponse(jsonDecode(body) as Map<String, dynamic>);
  } on SocketException {
    throw AiException('Ingen kontakt med Claude. Är du ansluten till internet?');
  } finally {
    client.close();
  }
}

/// Filerna som skickas: hämtade filer med utkast ovanpå.
Future<Map<String, String>> filesForAi(Map<String, String> drafts) async {
  final root = await workspaceDir();
  final out = <String, String>{};
  if (root.existsSync()) {
    for (final f in root.listSync(recursive: true).whereType<File>()) {
      out[f.path.substring(root.path.length + 1)] = f.readAsStringSync();
    }
  }
  return {
    for (final e in {...out, ...drafts}.entries)
      if (RegExp(r'^(apps|types|lang)/').hasMatch(e.key)) e.key: e.value,
  };
}

/// Enkel raddiff för att visa ett förslag: rader med '+', '-' eller ' ' först.
List<String> lineDiff(String before, String after) {
  final a = before.isEmpty ? <String>[] : before.trimRight().split('\n');
  final b = after.trimRight().split('\n');
  final n = a.length, m = b.length;
  final lcs = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = <String>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add('  ${a[i]}');
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.add('- ${a[i++]}');
    } else {
      out.add('+ ${b[j++]}');
    }
  }
  while (i < n) {
    out.add('- ${a[i++]}');
  }
  while (j < m) {
    out.add('+ ${b[j++]}');
  }
  return out;
}
