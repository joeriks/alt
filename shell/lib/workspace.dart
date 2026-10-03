import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';

import 'engine.dart';
import 'query.dart';

/// Arbetsytan: appar, samlingar och recept som hämtas från receptrepot på GitHub.
/// Den lokala kopian ligger i `workspace/` och byts bara ut när en hämtning lyckats helt.

const defaultRepo = 'joeriks/alt-my-recepies';
const _secure = FlutterSecureStorage();

Future<Directory> workspaceDir() async => Directory('${(await getApplicationSupportDirectory()).path}/workspace');

Future<String?> githubToken() => _secure.read(key: 'github_token');
Future<void> setGithubToken(String token) => _secure.write(key: 'github_token', value: token.trim());
Future<String> recipesRepo() async => (await _secure.read(key: 'recipes_repo')) ?? defaultRepo;

/// Ett fält i en samling. Skrivs i YAML som `datum: { date, required }`
/// eller `vem: { link: person }`.
class Field {
  Field({required this.name, required this.type, this.required = false, this.link, String? label})
    : label = label ?? name.replaceAll('_', ' ');

  /// Tekniskt namn, på engelska: `date`, `title`.
  final String name;

  /// Det som visas, till exempel "Datum". Utan `label:` visas namnet.
  final String label;
  final String type; // text, longtext, date, time, number, bool, link
  final bool required;
  final String? link;

  static const types = {'text', 'longtext', 'date', 'time', 'number', 'bool', 'link'};

  static Field parse(String name, dynamic spec) {
    var type = 'text';
    var req = false;
    String? link;
    String? label;
    if (spec is Map) {
      for (final e in spec.entries) {
        final k = e.key.toString();
        if (k == 'required') {
          req = e.value == null || e.value == true;
        } else if (k == 'label') {
          label = e.value?.toString();
        } else if (k == 'link') {
          type = 'link';
          link = e.value?.toString();
        } else if (types.contains(k)) {
          type = k;
        }
      }
    } else if (spec is String && types.contains(spec)) {
      type = spec;
    }
    return Field(name: name, type: type, required: req, link: link, label: label);
  }

  Field withLabel(String l) => Field(name: name, type: type, required: required, link: link, label: l);
}

/// Språkfilen som matchar telefonens språk, till exempel `lang/sv.yaml`.
Map<String, dynamic> loadLang(Map<String, String> files) {
  final code = Platform.localeName.split(RegExp('[_-]')).first.toLowerCase();
  final text = files['lang/$code.yaml'];
  if (text == null) return const {};
  return Map<String, dynamic>.from(jsonDecode(jsonEncode(loadYaml(text) ?? {})) as Map);
}

class Collection {
  Collection({
    required this.name,
    required this.app,
    required this.appLabel,
    required this.label,
    required this.fields,
    required this.role,
    required this.encrypted,
    required this.titleField,
    this.type,
  });

  final String name;
  final String app;
  final String appLabel;
  final String label;
  final List<Field> fields;
  final String? role;
  final bool encrypted;
  final String titleField;
  final String? type;

  Field? get dateField => fields.where((f) => f.type == 'date').firstOrNull;
  Field? get timeField => fields.where((f) => f.type == 'time').firstOrNull;

  /// [types] är de delade typerna från `types/*.type.yaml`. En samling med
  /// `type: dated_entry` får typens fält, roll och titel, och får lägga till egna
  /// fält men inte ändra typens.
  ///
  /// [lang] är språkfilen för telefonens språk (`lang/sv.yaml`). Den ersätter
  /// de engelska etiketterna; det som saknas där visas på engelska.
  static Collection parse(
    String name,
    String app,
    String appLabel,
    String source, {
    Map<String, Map<String, dynamic>> types = const {},
    Map<String, dynamic> lang = const {},
  }) {
    final y = loadYaml(source);
    final m = jsonDecode(jsonEncode(y)) as Map<String, dynamic>;
    final typeName = m['type']?.toString();
    final type = typeName == null ? null : types[typeName];
    if (typeName != null && type == null) throw FormatException('$name: typen $typeName finns inte');
    String? tr(List<String> path) {
      dynamic v = lang;
      for (final k in path) {
        if (v is! Map) return null;
        v = v[k];
      }
      return v is String ? v : null;
    }

    final fields = <Field>[];
    for (final src in [type?['fields'], m['fields']]) {
      if (src is! Map) continue;
      for (final e in src.entries) {
        var f = Field.parse(e.key.toString(), e.value);
        final override =
            tr(['collections', name, 'fields', f.name]) ??
            (typeName == null ? null : tr(['types', typeName, 'fields', f.name]));
        if (override != null) f = f.withLabel(override);
        if (fields.any((x) => x.name == f.name)) {
          throw FormatException('$name: fältet ${f.name} finns redan i typen $typeName och får inte ändras');
        }
        fields.add(f);
      }
    }
    if (fields.isEmpty) throw FormatException('$name saknar fields');
    String? pick(String key) => m[key]?.toString() ?? type?[key]?.toString();
    return Collection(
      name: name,
      app: app,
      appLabel: tr(['apps', app]) ?? appLabel,
      label: tr(['collections', name, 'label']) ?? m['label']?.toString() ?? name,
      fields: fields,
      role: pick('role'),
      encrypted: m['encrypted'] == true,
      titleField: pick('title') ?? fields.firstWhere((f) => f.type == 'text', orElse: () => fields.first).name,
      type: typeName,
    );
  }
}

class Workspace {
  Workspace(this.collections, this.recipes, this.problems, {this.queries = const [], this.recipePaths = const {}});

  final List<Collection> collections;
  final List<Recipe> recipes;

  /// Receptets namn → filens sökväg i receptrepot, för att kunna öppna filen från menyn.
  final Map<String, String> recipePaths;
  final List<Query> queries;

  /// Filer som inte gick att läsa, så att ett trasigt recept inte stoppar resten.
  final List<String> problems;

  Collection? collection(String name) => collections.where((c) => c.name == name).firstOrNull;

  /// [overlay] ersätter eller lägger till filer (relativ sökväg → text).
  /// Används av Utveckla för att prova utkast utan att röra den hämtade kopian.
  static Future<Workspace> load({Map<String, String> overlay = const {}}) async {
    final root = await workspaceDir();
    final files = <String, String>{};
    if (root.existsSync()) {
      for (final f in root.listSync(recursive: true).whereType<File>()) {
        files[f.path.substring(root.path.length + 1)] = f.readAsStringSync();
      }
    }
    files.addAll(overlay);
    return fromFiles(files);
  }

  static Workspace fromFiles(Map<String, String> files) {
    final paths = files.keys.toList()..sort();
    final collections = <Collection>[];
    final recipes = <Recipe>[];
    final recipePaths = <String, String>{};
    final queries = <Query>[];
    final problems = <String>[];
    var lang = const <String, dynamic>{};
    try {
      lang = loadLang(files);
    } catch (e) {
      problems.add('lang: $e');
    }
    final types = <String, Map<String, dynamic>>{};
    for (final p in paths) {
      final m = RegExp(r'^types/([^/]+)\.type\.yaml$').firstMatch(p);
      if (m == null) continue;
      try {
        types[m[1]!] = Map<String, dynamic>.from(jsonDecode(jsonEncode(loadYaml(files[p]!))) as Map);
      } catch (e) {
        problems.add('$p: $e');
      }
    }
    final appLabels = <String, String>{};
    for (final p in paths) {
      final m = RegExp(r'^apps/([^/]+)/').firstMatch(p);
      if (m == null) continue;
      final app = m[1]!;
      if (!appLabels.containsKey(app)) {
        appLabels[app] = app;
        final appFile = files['apps/$app/app.yaml'];
        if (appFile != null) {
          try {
            appLabels[app] = (loadYaml(appFile) as Map?)?['label']?.toString() ?? app;
          } catch (e) {
            problems.add('$app/app.yaml: $e');
          }
        }
      }
      final file = p.substring(m[0]!.length);
      if (file.contains('/')) continue;
      try {
        if (file.endsWith('.collection.yaml')) {
          final name = file.substring(0, file.length - '.collection.yaml'.length);
          collections.add(Collection.parse(name, app, appLabels[app]!, files[p]!, types: types, lang: lang));
        } else if (file.endsWith('.recipe')) {
          recipes.add(Recipe.parse(files[p]!));
          recipePaths[recipes.last.name] = p;
        } else if (file.endsWith('.query.yaml')) {
          final name = file.substring(0, file.length - '.query.yaml'.length);
          queries.add(Query.parse(name, app, appLabels[app]!, files[p]!, lang: lang));
        }
      } catch (e) {
        problems.add('$app/$file: $e');
      }
    }
    for (final c in collections) {
      for (final f in c.fields.where((f) => f.type == 'link')) {
        if (!collections.any((x) => x.name == f.link)) {
          problems.add(
            '${c.app}/${c.name}.collection.yaml: fältet ${f.name} kopplar till samlingen ${f.link}, som inte finns',
          );
        }
      }
    }
    for (final q in queries) {
      final missing = [
        for (final f in q.from)
          if (!collections.any((c) => c.name == f)) f,
      ];
      if (missing.isNotEmpty) problems.add('${q.app}/${q.name}.query.yaml: samlingen ${missing.join(', ')} finns inte');
    }
    return Workspace(collections, recipes, problems, queries: queries, recipePaths: recipePaths);
  }
}

/// Hämtar alla filer under `apps/`, `types/` och `lang/` från receptrepot. Returnerar antal filer.
Future<int> syncWorkspace() async {
  final token = await githubToken();
  if (token == null || token.isEmpty) throw StateError('ingen GitHub-nyckel, kör System / Koppla GitHub');
  final repo = await recipesRepo();
  final client = HttpClient();
  Future<List<int>> get(String url, {bool raw = false}) async {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.set('Accept', raw ? 'application/vnd.github.raw' : 'application/vnd.github+json');
    req.headers.set('X-GitHub-Api-Version', '2022-11-28');
    final res = await req.close();
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    if (res.statusCode != 200) throw HttpException('GitHub svarade ${res.statusCode} för $url');
    return body;
  }

  try {
    final repoInfo = jsonDecode(utf8.decode(await get('https://api.github.com/repos/$repo'))) as Map;
    final branch = repoInfo['default_branch'] ?? 'main';
    final tree =
        jsonDecode(utf8.decode(await get('https://api.github.com/repos/$repo/git/trees/$branch?recursive=1'))) as Map;
    final paths = [
      for (final t in (tree['tree'] as List))
        if (t['type'] == 'blob' && RegExp(r'^(apps|types|lang)/').hasMatch(t['path'] as String)) t['path'] as String,
    ];
    final root = await workspaceDir();
    final tmp = Directory('${root.path}.new');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    for (final p in paths) {
      final bytes = await get(
        'https://api.github.com/repos/$repo/contents/${Uri.encodeFull(p)}?ref=$branch',
        raw: true,
      );
      final f = File('${tmp.path}/$p');
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(bytes);
    }
    tmp.createSync(recursive: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
    tmp.renameSync(root.path);
    return paths.length;
  } finally {
    client.close();
  }
}
