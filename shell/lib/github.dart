import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'workspace.dart';

/// Sparar utkast till receptrepot som en enda commit.
///
/// Innan något skrivs kontrolleras att varje fil på GitHub är densamma som
/// den du hämtade senast, så att en ändring gjord någon annanstans inte skrivs över.

class PublishException implements Exception {
  PublishException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Gits id för en fil: sha1 av `blob <längd>\0<innehåll>`.
String gitBlobSha(List<int> bytes) => sha1.convert([...utf8.encode('blob ${bytes.length}\u0000'), ...bytes]).toString();

/// Filer vars version på GitHub inte är den man hämtade. [remote] och [local] är sökväg → blob-sha.
List<String> changedSinceSync(Iterable<String> paths, Map<String, String> remote, Map<String, String> local) => [
  for (final p in paths)
    if (remote[p] != local[p]) p,
];

class _GitHub {
  _GitHub(this.token, this.repo);
  final String token;
  final String repo;
  final _client = HttpClient();

  Future<Map<String, dynamic>> call(String method, String path, [Object? body]) async {
    final req = await _client.openUrl(method, Uri.parse('https://api.github.com/repos/$repo$path'));
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.set('Accept', 'application/vnd.github+json');
    req.headers.set('X-GitHub-Api-Version', '2022-11-28');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode == 401) throw PublishException('GitHub-nyckeln godtogs inte.');
    if (res.statusCode == 403 || (res.statusCode == 404 && method != 'GET')) {
      var detail = '';
      try {
        detail = '\n\nGitHub: ${(jsonDecode(text) as Map)['message']}';
      } catch (_) {}
      throw PublishException(
        'Nyckeln får inte skriva till ${repo.split('/').last}. '
        'Ge den "Contents: Read and write" på GitHub och kör System / Koppla GitHub igen.$detail',
      );
    }
    if (res.statusCode == 409 || res.statusCode == 422) {
      throw PublishException('Receptrepot ändrades samtidigt. Kör System / Hämta recept och spara igen.');
    }
    if (res.statusCode >= 300) throw PublishException('GitHub svarade ${res.statusCode}.');
    return jsonDecode(text) as Map<String, dynamic>;
  }

  void close() => _client.close();
}

/// Skriver [files] (relativ sökväg → text) till receptrepot och till den lokala kopian.
/// Returnerar commitens korta id.
Future<String> publishFiles(Map<String, String> files, String message) async {
  final token = await githubToken();
  if (token == null || token.isEmpty) {
    throw PublishException('Ingen GitHub-nyckel. Kör System / Koppla GitHub.');
  }
  final gh = _GitHub(token, await recipesRepo());
  try {
    final branch = (await gh.call('GET', ''))['default_branch'] ?? 'main';
    final head = (await gh.call('GET', '/git/ref/heads/$branch'))['object']['sha'] as String;
    final baseTree = (await gh.call('GET', '/git/commits/$head'))['tree']['sha'] as String;
    final tree = await gh.call('GET', '/git/trees/$baseTree?recursive=1');
    final remote = {
      for (final t in (tree['tree'] as List))
        if (t['type'] == 'blob') t['path'] as String: t['sha'] as String,
    };
    final root = await workspaceDir();
    final local = <String, String>{};
    for (final p in files.keys) {
      final f = File('${root.path}/$p');
      if (f.existsSync()) local[p] = gitBlobSha(f.readAsBytesSync());
    }
    final changed = changedSinceSync(files.keys, remote, local);
    if (changed.isNotEmpty) {
      throw PublishException(
        '${changed.join(', ')} har ändrats på GitHub sedan du hämtade. '
        'Kör System / Hämta recept, titta på skillnaden och spara igen. Dina utkast finns kvar.',
      );
    }
    final newTree = await gh.call('POST', '/git/trees', {
      'base_tree': baseTree,
      'tree': [
        for (final e in files.entries) {'path': e.key, 'mode': '100644', 'type': 'blob', 'content': e.value},
      ],
    });
    final commit = await gh.call('POST', '/git/commits', {
      'message': message,
      'tree': newTree['sha'],
      'parents': [head],
    });
    await gh.call('PATCH', '/git/refs/heads/$branch', {'sha': commit['sha'], 'force': false});
    for (final e in files.entries) {
      final f = File('${root.path}/${e.key}');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(e.value, flush: true);
    }
    return (commit['sha'] as String).substring(0, 7);
  } on SocketException {
    throw PublishException('Ingen kontakt med GitHub. Är du ansluten till internet?');
  } finally {
    gh.close();
  }
}
