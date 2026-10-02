import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';

import 'engine.dart';

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
  Field({required this.name, required this.type, this.required = false, this.link});

  final String name;
  final String type; // text, longtext, date, time, number, bool, link
  final bool required;
  final String? link;

  static const types = {'text', 'longtext', 'date', 'time', 'number', 'bool', 'link'};

  static Field parse(String name, dynamic spec) {
    var type = 'text';
    var req = false;
    String? link;
    if (spec is Map) {
      for (final e in spec.entries) {
        final k = e.key.toString();
        if (k == 'required') {
          req = e.value == null || e.value == true;
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
    return Field(name: name, type: type, required: req, link: link);
  }

  String get label => name.replaceAll('_', ' ');
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
  /// `type: datumpost` får typens fält, roll och titel, och får lägga till egna
  /// fält men inte ändra typens.
  static Collection parse(
    String name,
    String app,
    String appLabel,
    String source, {
    Map<String, Map<String, dynamic>> types = const {},
  }) {
    final y = loadYaml(source);
    final m = jsonDecode(jsonEncode(y)) as Map<String, dynamic>;
    final typeName = m['type']?.toString();
    final type = typeName == null ? null : types[typeName];
    if (typeName != null && type == null) throw FormatException('$name: typen $typeName finns inte');
    final fields = <Field>[];
    for (final src in [type?['fields'], m['fields']]) {
      if (src is! Map) continue;
      for (final e in src.entries) {
        final f = Field.parse(e.key.toString(), e.value);
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
      appLabel: appLabel,
      label: m['label']?.toString() ?? name,
      fields: fields,
      role: pick('role'),
      encrypted: m['encrypted'] != false,
      titleField: pick('title') ?? fields.firstWhere((f) => f.type == 'text', orElse: () => fields.first).name,
      type: typeName,
    );
  }
}

class Workspace {
  Workspace(this.collections, this.recipes, this.problems);

  final List<Collection> collections;
  final List<Recipe> recipes;

  /// Filer som inte gick att läsa, så att ett trasigt recept inte stoppar resten.
  final List<String> problems;

  Collection? collection(String name) => collections.where((c) => c.name == name).firstOrNull;

  static Future<Workspace> load() async {
    final root = await workspaceDir();
    final collections = <Collection>[];
    final recipes = <Recipe>[];
    final problems = <String>[];
    final types = <String, Map<String, dynamic>>{};
    final typeDir = Directory('${root.path}/types');
    if (typeDir.existsSync()) {
      for (final f in typeDir.listSync().whereType<File>().where((f) => f.path.endsWith('.type.yaml'))) {
        final file = f.uri.pathSegments.last;
        try {
          types[file.substring(0, file.length - '.type.yaml'.length)] = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(loadYaml(f.readAsStringSync()))) as Map,
          );
        } catch (e) {
          problems.add('types/$file: $e');
        }
      }
    }
    final apps = Directory('${root.path}/apps');
    if (apps.existsSync()) {
      final appDirs = apps.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
      for (final dir in appDirs) {
        final app = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
        var appLabel = app;
        final appFile = File('${dir.path}/app.yaml');
        if (appFile.existsSync()) {
          try {
            appLabel = (loadYaml(appFile.readAsStringSync()) as Map?)?['label']?.toString() ?? app;
          } catch (e) {
            problems.add('$app/app.yaml: $e');
          }
        }
        final files = dir.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
        for (final f in files) {
          final file = f.uri.pathSegments.last;
          try {
            if (file.endsWith('.collection.yaml')) {
              final name = file.substring(0, file.length - '.collection.yaml'.length);
              collections.add(Collection.parse(name, app, appLabel, f.readAsStringSync(), types: types));
            } else if (file.endsWith('.recipe')) {
              recipes.add(Recipe.parse(f.readAsStringSync()));
            }
          } catch (e) {
            problems.add('$app/$file: $e');
          }
        }
      }
    }
    return Workspace(collections, recipes, problems);
  }
}

/// Hämtar alla filer under `apps/` och `types/` från receptrepot. Returnerar antal filer.
Future<int> syncWorkspace() async {
  final token = await githubToken();
  if (token == null || token.isEmpty) throw StateError('ingen GitHub-nyckel, lägg in den under Inställningar / GitHub');
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
        if (t['type'] == 'blob' && RegExp(r'^(apps|types)/').hasMatch(t['path'] as String)) t['path'] as String,
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
