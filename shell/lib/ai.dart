import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'workspace.dart';

/// AI-styrning: du beskriver en ändring med egna ord, AI:n (Claude eller OpenAI) skriver om filerna
/// i receptrepot, och resultatet blir utkast som du provar innan något sparas.
///
/// Det enda som skickas är filerna från receptrepot (apps/, types/, lang/) och
/// dina utkast. Poster, körlogg och lagrade värden skickas aldrig.

const _secure = FlutterSecureStorage();

/// Billiga modeller: en vanlig ändring kostar några öre.
const model = 'claude-haiku-4-5';
const openAiModel = 'gpt-5.4-nano';

/// Pris i USD per miljon token (in, ut) och en ungefärlig växelkurs, för att visa kostnaden.
const _prices = {model: (1.0, 5.0), openAiModel: (0.20, 1.25)};
const _sekPerUsd = 10.0;

enum AiService { claude, openai }

extension AiServiceName on AiService {
  String get label => this == AiService.claude ? 'Claude' : 'OpenAI';
  String get modelName => this == AiService.claude ? model : openAiModel;
}

Future<String?> claudeKey() => _secure.read(key: 'anthropic_key');
Future<String?> openAiKey() => _secure.read(key: 'openai_key');

/// Att lägga in en nyckel väljer också den tjänsten.
Future<void> setClaudeKey(String key) async {
  await _secure.write(key: 'anthropic_key', value: key.trim());
  await setAiService(AiService.claude);
}

Future<void> setOpenAiKey(String key) async {
  await _secure.write(key: 'openai_key', value: key.trim());
  await setAiService(AiService.openai);
}

Future<AiService> aiService() async =>
    (await _secure.read(key: 'ai_service')) == 'openai' ? AiService.openai : AiService.claude;
Future<void> setAiService(AiService s) => _secure.write(key: 'ai_service', value: s.name);

const aiRules = '''
Du ändrar filerna i en persons receptrepo för appen alt, en Android-app där användaren bygger egna små appar utan att bygga om appen.
Svara med de filer som ska ändras eller skapas, med HELA det nya innehållet i varje fil. Skriv alltid en kort sammanfattning på svenska av vad du ändrade i summary, en eller två meningar.
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

/// Kostnad i öre för ett anrop med [modelId], från antal token in och ut.
double? costOre(String modelId, num? input, num? output) {
  final price = _prices[modelId];
  if (price == null || input == null || output == null) return null;
  return (input * price.$1 + output * price.$2) / 1e6 * _sekPerUsd * 100;
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

String _userMessage(String ask, Map<String, String> files) {
  final listing = StringBuffer();
  for (final e in (files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) {
    listing.writeln('<file path="${e.key}">\n${e.value}\n</file>');
  }
  return 'Receptrepots filer just nu:\n\n$listing\nÄndring jag vill ha:\n$ask';
}

/// Bygger förfrågan till Claude. [files] är relativ sökväg → innehåll.
Map<String, dynamic> buildRequest(String ask, Map<String, String> files) => {
  'model': model,
  'max_tokens': 8000,
  'output_config': {
    'format': {'type': 'json_schema', 'schema': _schema},
  },
  'system': aiRules,
  'messages': [
    {'role': 'user', 'content': _userMessage(ask, files)},
  ],
};

/// Bygger förfrågan till OpenAI (Chat Completions med JSON-schema).
Map<String, dynamic> buildOpenAiRequest(String ask, Map<String, String> files) => {
  'model': openAiModel,
  'max_completion_tokens': 8000,
  'reasoning_effort': 'low',
  'response_format': {
    'type': 'json_schema',
    'json_schema': {'name': 'proposal', 'strict': true, 'schema': _schema},
  },
  'messages': [
    {'role': 'system', 'content': aiRules},
    {'role': 'user', 'content': _userMessage(ask, files)},
  ],
};

final _pathRule = RegExp(r'^(apps/[a-zåäö][a-zåäö0-9_]*/[a-zåäö0-9_.]+|types/[a-z0-9_.]+|lang/[a-z]{2}\.yaml)$');

/// Tolkar förslaget. Kastar AiException för filer utanför apps/, types/ och lang/.
AiProposal _proposal(String text, double? ore) {
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
      throw AiException('AI:n föreslog en fil utanför receptrepots mappar: $path');
    }
    files.add(AiFile(path, f['content'] as String));
  }
  return AiProposal((data['summary'] ?? '').toString(), files, ore: ore);
}

const _tooLong = 'Svaret blev för långt och avbröts. Försök med en mindre ändring.';

/// Tolkar Claudes svar. Kastar AiException om Claude avböjde eller svaret blev avkortat.
AiProposal parseResponse(Map<String, dynamic> res) {
  final stop = res['stop_reason'];
  if (stop == 'refusal') throw AiException('Claude avböjde förfrågan.');
  if (stop == 'max_tokens') throw AiException(_tooLong);
  final text = [
    for (final b in (res['content'] as List? ?? const []))
      if (b is Map && b['type'] == 'text') b['text'] as String,
  ].join();
  final usage = res['usage'] as Map<String, dynamic>?;
  final input = usage == null
      ? null
      : (usage['input_tokens'] as num? ?? 0) + (usage['cache_creation_input_tokens'] as num? ?? 0);
  return _proposal(text, costOre(model, input, usage?['output_tokens'] as num?));
}

/// Tolkar OpenAIs svar.
AiProposal parseOpenAiResponse(Map<String, dynamic> res) {
  final choice = ((res['choices'] as List?) ?? const []).firstOrNull as Map?;
  if (choice == null) throw AiException('Svaret gick inte att läsa.');
  final message = choice['message'] as Map? ?? const {};
  if (message['refusal'] != null) throw AiException('OpenAI avböjde förfrågan: ${message['refusal']}');
  if (choice['finish_reason'] == 'length') throw AiException(_tooLong);
  final usage = res['usage'] as Map<String, dynamic>?;
  return _proposal(
    (message['content'] ?? '').toString(),
    costOre(openAiModel, usage?['prompt_tokens'] as num?, usage?['completion_tokens'] as num?),
  );
}

/// Skickar ändringen till den valda AI-tjänsten och returnerar förslaget.
Future<AiProposal> askAi(String ask, Map<String, String> files) async {
  final service = await aiService();
  final key = service == AiService.claude ? await claudeKey() : await openAiKey();
  final name = service.label;
  if (key == null || key.isEmpty) {
    throw AiException('Ingen $name-nyckel. Lägg in den under System / AI / $name-nyckel.');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final HttpClientRequest req;
    if (service == AiService.claude) {
      req = await client.postUrl(Uri.parse('https://api.anthropic.com/v1/messages'));
      req.headers.set('x-api-key', key);
      req.headers.set('anthropic-version', '2023-06-01');
    } else {
      req = await client.postUrl(Uri.parse('https://api.openai.com/v1/chat/completions'));
      req.headers.set('Authorization', 'Bearer $key');
    }
    req.headers.contentType = ContentType.json;
    final body = service == AiService.claude ? buildRequest(ask, files) : buildOpenAiRequest(ask, files);
    req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close().timeout(const Duration(minutes: 5));
    final text = await res.transform(utf8.decoder).join();
    String apiMessage() {
      try {
        return (jsonDecode(text) as Map)['error']['message'].toString();
      } catch (_) {
        return text;
      }
    }

    if (res.statusCode == 401) throw AiException('$name-nyckeln godtogs inte.');
    if (res.statusCode == 429) throw AiException('$name säger nej just nu: ${apiMessage()}');
    if (res.statusCode >= 500) {
      throw AiException('$name svarar inte just nu (${res.statusCode}). Försök igen om en stund.');
    }
    if (res.statusCode != 200) throw AiException('Fel ${res.statusCode} från $name: ${apiMessage()}');
    final json = jsonDecode(text) as Map<String, dynamic>;
    return service == AiService.claude ? parseResponse(json) : parseOpenAiResponse(json);
  } on SocketException {
    throw AiException('Ingen kontakt med $name. Är du ansluten till internet?');
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
