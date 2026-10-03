import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:yaml/yaml.dart';

import 'github.dart' show gitBlobSha;
import 'records.dart';
import 'workspace.dart';

/// Synk av poster mellan telefonen och datarepot (alt-my-data).
///
/// En fil per post. Samlingar med `encrypted: true` (valfritt, av som standard eftersom repot är privat) krypteras med en nyckel
/// som räknas fram ur användarens lösenfras; filnamnet blir då en HMAC av postens id så att
/// inte heller titeln syns. `.alt/crypto.json` i repot håller salt och en kontrollsträng,
/// så att samma lösenfras ger samma nyckel på en annan telefon och en felskriven fras märks.
///
/// Telefonen minns vid varje synk vilken version av varje post den och GitHub var överens om.
/// Har bara den ena sidan ändrats vinner den; har båda ändrats blir det en krock som användaren löser.

const defaultDataRepo = 'joeriks/alt-my-data';
const _secure = FlutterSecureStorage();
const _cryptoPath = '.alt/crypto.json';
const _check = 'alt-my-data';

Future<String> dataRepo() async => (await _secure.read(key: 'data_repo')) ?? defaultDataRepo;
Future<List<int>?> _dataKey() async {
  final k = await _secure.read(key: 'data_key');
  return k == null ? null : base64Decode(k);
}

Future<bool> hasDataKey() async => (await _dataKey()) != null;

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ---------------------------------------------------------------- kryptering

final _aes = AesGcm.with256bits();

/// Nyckeln ur lösenfrasen. Tar någon sekund, så den körs utanför UI-tråden.
Future<List<int>> deriveKey(String passphrase, List<int> salt, int iterations) => Isolate.run(() async {
  final k = await Pbkdf2.hmacSha256(
    iterations: iterations,
    bits: 256,
  ).deriveKeyFromPassword(password: passphrase, nonce: salt);
  return k.extractBytes();
});

Future<String> encryptText(String text, List<int> key) async {
  final box = await _aes.encrypt(utf8.encode(text), secretKey: SecretKey(key));
  return 'alt-enc-1 ${base64Encode(box.concatenation())}\n';
}

Future<String> decryptText(String data, List<int> key) async {
  final parts = data.trim().split(' ');
  if (parts.length != 2 || parts[0] != 'alt-enc-1') throw SyncException('Okänt filformat i datarepot.');
  final box = SecretBox.fromConcatenation(base64Decode(parts[1]), nonceLength: 12, macLength: 16);
  try {
    return utf8.decode(await _aes.decrypt(box, secretKey: SecretKey(key)));
  } on SecretBoxAuthenticationError {
    throw SyncException('En fil i datarepot gick inte att låsa upp. Är lösenfrasen rätt?');
  }
}

/// Filnamn för en krypterad post: samma id ger alltid samma namn, men namnet avslöjar inget.
String encryptedName(String collection, String id, List<int> key) =>
    '$collection/${hash.Hmac(hash.sha256, key).convert(utf8.encode('$collection/$id')).toString().substring(0, 32)}.enc';

// ---------------------------------------------------------------- GitHub

/// Det synken behöver av datarepot. Ersätts av en låtsasversion i testerna.
abstract class DataRemote {
  /// Senaste commit och alla filer i den (sökväg → blob-sha). Null om repot är tomt.
  Future<({String head, Map<String, String> files})?> snapshot();
  Future<String> read(String sha);

  /// Skriver filerna (null tar bort) som en commit ovanpå [head]. Kastar [SyncConflict] om någon hann före.
  Future<void> commit(String? head, Map<String, String?> files, String message);
}

class SyncConflict implements Exception {}

class GitHubRemote implements DataRemote {
  GitHubRemote(this.token, this.repo);
  final String token;
  final String repo;
  final _client = HttpClient();
  String _branch = 'main';

  Future<(int, dynamic)> _call(String method, String path, [Object? body]) async {
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
    final name = repo.split('/').last;
    if (res.statusCode == 401) throw SyncException('GitHub-nyckeln godtogs inte.');
    if (res.statusCode == 403 || (res.statusCode == 404 && path.isEmpty)) {
      throw SyncException(
        'Nyckeln kommer inte åt $name. Ge den "Contents: Read and write" för $name på GitHub '
        'och lägg in den igen under System / GitHub-nyckel.',
      );
    }
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  @override
  Future<({String head, Map<String, String> files})?> snapshot() async {
    final (_, info) = await _call('GET', '');
    _branch = (info as Map)['default_branch']?.toString() ?? 'main';
    final (s, ref) = await _call('GET', '/git/ref/heads/$_branch');
    if (s == 404 || s == 409) return null;
    if (s != 200) throw SyncException('GitHub svarade $s.');
    final head = ref['object']['sha'] as String;
    final (_, commit) = await _call('GET', '/git/commits/$head');
    final (_, tree) = await _call('GET', '/git/trees/${commit['tree']['sha']}?recursive=1');
    return (
      head: head,
      files: {
        for (final t in (tree['tree'] as List))
          if (t['type'] == 'blob') t['path'] as String: t['sha'] as String,
      },
    );
  }

  @override
  Future<String> read(String sha) async {
    final (s, blob) = await _call('GET', '/git/blobs/$sha');
    if (s != 200) throw SyncException('GitHub svarade $s.');
    return utf8.decode(base64Decode((blob['content'] as String).replaceAll('\n', '')));
  }

  @override
  Future<void> commit(String? head, Map<String, String?> files, String message) async {
    if (head == null) {
      // Ett tomt repo har ingen gren att bygga på; den första filen skapar den.
      final first = files.entries.firstWhere((e) => e.value != null);
      final (s, _) = await _call('PUT', '/contents/${Uri.encodeFull(first.key)}', {
        'message': message,
        'content': base64Encode(utf8.encode(first.value!)),
      });
      if (s == 422 || s == 409) throw SyncConflict();
      if (s >= 300) throw SyncException('GitHub svarade $s.');
      final rest = Map.of(files)..remove(first.key);
      if (rest.isEmpty) return;
      final snap = await snapshot();
      return commit(snap!.head, rest, message);
    }
    final (_, base) = await _call('GET', '/git/commits/$head');
    final (s1, tree) = await _call('POST', '/git/trees', {
      'base_tree': base['tree']['sha'],
      'tree': [
        for (final e in files.entries)
          // sha: null tar bort filen.
          e.value == null
              ? {'path': e.key, 'mode': '100644', 'type': 'blob', 'sha': null}
              : {'path': e.key, 'mode': '100644', 'type': 'blob', 'content': e.value},
      ],
    });
    if (s1 >= 300) throw SyncException('GitHub svarade $s1.');
    final (s2, made) = await _call('POST', '/git/commits', {
      'message': message,
      'tree': tree['sha'],
      'parents': [head],
    });
    if (s2 >= 300) throw SyncException('GitHub svarade $s2.');
    final (s3, _) = await _call('PATCH', '/git/refs/heads/$_branch', {'sha': made['sha'], 'force': false});
    if (s3 == 422 || s3 == 409) throw SyncConflict();
    if (s3 >= 300) throw SyncException('GitHub svarade $s3.');
  }

  void close() => _client.close();
}

// ---------------------------------------------------------------- lösenfras

/// Sparar nyckeln för lösenfrasen. Finns redan en lösenfras i datarepot måste den vara samma.
/// Själva frasen sparas aldrig, bara nyckeln (i telefonens Keystore).
Future<void> setPassphrase(String passphrase, {DataRemote? remote}) async {
  final r = remote ?? await _gitHub();
  try {
    final snap = await r.snapshot();
    final existing = snap?.files[_cryptoPath];
    if (existing != null) {
      final info = jsonDecode(await r.read(existing)) as Map;
      final key = await deriveKey(passphrase, base64Decode(info['salt']), info['iterations'] as int);
      if (await decryptText(info['check'], key).catchError((_) => '') != _check) {
        throw SyncException('Lösenfrasen stämmer inte med den som redan används för datarepot.');
      }
      await _secure.write(key: 'data_key', value: base64Encode(key));
      return;
    }
    final rnd = Random.secure();
    final salt = [for (var i = 0; i < 16; i++) rnd.nextInt(256)];
    const iterations = 310000;
    final key = await deriveKey(passphrase, salt, iterations);
    final info = jsonEncode({
      'kdf': 'pbkdf2-hmac-sha256',
      'iterations': iterations,
      'salt': base64Encode(salt),
      'cipher': 'aes-256-gcm',
      'check': (await encryptText(_check, key)).trim(),
    });
    await r.commit(snap?.head, {_cryptoPath: '$info\n'}, 'Lösenfras för krypterade samlingar');
    await _secure.write(key: 'data_key', value: base64Encode(key));
  } finally {
    if (r is GitHubRemote) r.close();
  }
}

Future<GitHubRemote> _gitHub() async {
  final token = await githubToken();
  if (token == null || token.isEmpty) {
    throw SyncException('Ingen GitHub-nyckel. Lägg in den under System / GitHub-nyckel.');
  }
  return GitHubRemote(token, await dataRepo());
}

// ---------------------------------------------------------------- synk

/// En post som ändrats både här och på GitHub sedan förra synken.
class SyncClash {
  SyncClash(this.collection, this.id, this.mine, this.theirs, this.remoteSha);
  final String collection;
  final String id;

  /// Null om posten är borttagen på den sidan.
  final Map<String, dynamic>? mine;
  final Map<String, dynamic>? theirs;
  final String? remoteSha;
}

class SyncResult {
  SyncResult({this.sent = 0, this.received = 0, this.clashes = const [], this.locked = const []});
  final int sent;
  final int received;
  final List<SyncClash> clashes;

  /// Krypterade samlingar som inte synkats för att lösenfrasen saknas.
  final List<String> locked;

  String get summary {
    final parts = [
      if (sent > 0) 'skickade $sent',
      if (received > 0) 'tog emot $received',
      if (clashes.isNotEmpty) '${clashes.length} ${clashes.length == 1 ? 'krock' : 'krockar'}',
      if (locked.isNotEmpty) '${locked.join(', ')} väntar på lösenfras',
    ];
    return parts.isEmpty ? 'allt är synkat' : parts.join(', ');
  }
}

/// Vad telefonen och GitHub senast var överens om, per post (`samling/id`).
class _Seen {
  _Seen(this.path, this.remote, this.local);
  final String path;
  final String remote;
  final String local;
  Map<String, String> toJson() => {'path': path, 'remote': remote, 'local': local};
}

Future<File> _stateFile() async => File('${(await dataDir()).path}/.sync.json');

Future<Map<String, _Seen>> _loadState() async {
  final f = await _stateFile();
  if (!f.existsSync()) return {};
  final m = jsonDecode(f.readAsStringSync()) as Map;
  return {for (final e in m.entries) e.key as String: _Seen(e.value['path'], e.value['remote'], e.value['local'])};
}

Future<void> _saveState(Map<String, _Seen> s) async {
  (await _stateFile()).writeAsStringSync(jsonEncode({for (final e in s.entries) e.key: e.value.toJson()}), flush: true);
}

String _canon(Map<String, dynamic> v) =>
    jsonEncode(Map.fromEntries(v.entries.toList()..sort((a, b) => a.key.compareTo(b.key))));
String _localHash(Map<String, dynamic> v) => gitBlobSha(utf8.encode(_canon(v)));

String _plainText(Map<String, dynamic> v) =>
    '${[for (final e in (v.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) '${e.key}: ${jsonEncode(e.value)}'].join('\n')}\n';

bool _running = false;

/// Synkar alla poster. [resolved] är krockar användaren valt sida för: true behåller den här telefonens version.
Future<SyncResult> syncData({DataRemote? remote, Map<String, bool> resolved = const {}}) async {
  if (_running) return SyncResult();
  _running = true;
  DataRemote? r;
  try {
    r = remote ?? await _gitHub();
    for (var attempt = 0; ; attempt++) {
      try {
        return await _syncOnce(r, resolved);
      } on SyncConflict {
        if (attempt >= 2) throw SyncException('Datarepot ändrades samtidigt flera gånger. Försök igen.');
      }
    }
  } on SocketException {
    throw SyncException('Ingen kontakt med GitHub. Posterna ligger kvar på telefonen.');
  } finally {
    _running = false;
    if (r is GitHubRemote) r.close();
  }
}

Future<SyncResult> _syncOnce(DataRemote r, Map<String, bool> resolved) async {
  final ws = await Workspace.load();
  final encrypted = {for (final c in ws.collections) c.name: c.encrypted};
  final key = await _dataKey();
  final state = await _loadState();
  final snap = await r.snapshot();
  final remoteFiles = snap?.files ?? const <String, String>{};
  final cryptoSha = remoteFiles[_cryptoPath];
  if (key != null && cryptoSha == null && snap != null && remoteFiles.keys.any((p) => p.endsWith('.enc'))) {
    throw SyncException('Datarepot saknar $_cryptoPath. Lägg in lösenfrasen igen under System / Data / Lösenfras.');
  }

  // Lokala poster.
  final root = await dataDir();
  final local = <String, Map<String, dynamic>>{};
  if (root.existsSync()) {
    for (final d in root.listSync().whereType<Directory>()) {
      final coll = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (coll.startsWith('.')) continue;
      for (final rec in await listRecords(coll)) {
        local['$coll/${rec.id}'] = rec.values;
      }
    }
  }

  final locked = <String>{};
  bool usable(String coll) {
    if (encrypted[coll] != false && key == null) {
      locked.add(coll);
      return false;
    }
    return true;
  }

  String pathFor(String coll, String id) => encrypted[coll] != false ? encryptedName(coll, id, key!) : '$coll/$id.yaml';

  // GitHubs poster: läs bara filer som ändrats sedan förra synken.
  final known = {for (final e in state.entries) e.value.path: e.key};
  final remote = <String, ({String path, String sha, Map<String, dynamic>? values})>{};
  for (final e in remoteFiles.entries) {
    final p = e.key;
    if (p.startsWith('.') || !(p.endsWith('.yaml') || p.endsWith('.enc')) || !p.contains('/')) continue;
    final coll = p.split('/').first;
    final k = known[p];
    if (k != null && state[k]!.remote == e.value) {
      remote[k] = (path: p, sha: e.value, values: null);
      continue;
    }
    if (p.endsWith('.enc')) {
      if (key == null) {
        locked.add(coll);
        continue;
      }
      final m = jsonDecode(await decryptText(await r.read(e.value), key)) as Map;
      remote['$coll/${m['id']}'] = (path: p, sha: e.value, values: Map<String, dynamic>.from(m['values'] as Map));
    } else {
      final id = p.split('/').last.replaceAll('.yaml', '');
      final y = loadYaml(await r.read(e.value));
      remote['$coll/$id'] = (path: p, sha: e.value, values: Map<String, dynamic>.from(jsonDecode(jsonEncode(y ?? {}))));
    }
  }

  final upload = <String, String?>{};
  final newState = Map.of(state);
  final writes = <String, Map<String, dynamic>?>{};
  final clashes = <SyncClash>[];

  Future<void> send(String k, Map<String, dynamic>? v, String? oldPath) async {
    final coll = k.split('/').first, id = k.substring(coll.length + 1);
    if (v == null) {
      if (oldPath != null) upload[oldPath] = null;
      newState.remove(k);
      return;
    }
    final path = pathFor(coll, id);
    upload[path] = encrypted[coll] != false
        ? await encryptText(jsonEncode({'id': id, 'values': v}), key!)
        : _plainText(v);
    if (oldPath != null && oldPath != path) upload[oldPath] = null;
    newState[k] = _Seen(path, '', _localHash(v)); // remote-sha fylls i efter commit
  }

  for (final k in {...local.keys, ...remote.keys, ...state.keys}) {
    final coll = k.split('/').first;
    if (!usable(coll)) continue;
    final seen = state[k];
    final mine = local[k];
    final theirs = remote[k];
    final localChanged = mine == null ? seen != null : seen?.local != _localHash(mine);
    final remoteChanged = theirs == null ? seen != null : seen?.remote != theirs.sha;
    final pathMoved = mine != null && seen != null && seen.path != pathFor(coll, k.substring(coll.length + 1));

    if (!localChanged && !remoteChanged) {
      if (pathMoved) await send(k, mine, seen.path);
      continue;
    }
    if (localChanged && !remoteChanged) {
      await send(k, mine, theirs?.path ?? seen?.path);
      continue;
    }
    if (!localChanged && remoteChanged) {
      writes[k] = theirs?.values;
      if (theirs == null) {
        newState.remove(k);
      } else {
        newState[k] = _Seen(theirs.path, theirs.sha, _localHash(theirs.values!));
      }
      continue;
    }
    // Båda har ändrats.
    if (mine == null && theirs == null) {
      newState.remove(k);
      continue;
    }
    if (mine != null && theirs?.values != null && _canon(mine) == _canon(theirs!.values!)) {
      newState[k] = _Seen(theirs.path, theirs.sha, _localHash(mine));
      continue;
    }
    final choice = resolved[k];
    if (choice == true) {
      await send(k, mine, theirs?.path ?? seen?.path);
    } else if (choice == false) {
      writes[k] = theirs?.values;
      if (theirs == null) {
        newState.remove(k);
      } else {
        newState[k] = _Seen(theirs.path, theirs.sha, _localHash(theirs.values!));
      }
    } else {
      clashes.add(SyncClash(coll, k.substring(coll.length + 1), mine, theirs?.values, theirs?.sha));
    }
  }

  if (upload.isNotEmpty) {
    final n = upload.values.where((v) => v != null).length, d = upload.length - n;
    await r.commit(
      snap?.head,
      upload,
      [if (n > 0) '$n ${n == 1 ? 'post' : 'poster'}', if (d > 0) '$d borttagna'].join(', '),
    );
    // Blob-sha för det vi skickade räknas ut lokalt, så nästa synk ser att GitHub har samma version.
    for (final e in newState.entries.toList()) {
      final content = upload[e.value.path];
      if (content != null) newState[e.key] = _Seen(e.value.path, gitBlobSha(utf8.encode(content)), e.value.local);
    }
  }

  var received = 0;
  for (final e in writes.entries) {
    final coll = e.key.split('/').first, id = e.key.substring(coll.length + 1);
    final current = await readRecord(coll, id);
    if (e.value == null) {
      if (current != null) await deleteRecord(current, notify: false);
    } else {
      await restoreRecord(Rec(coll, id, e.value!), keepHistory: true, notify: false);
    }
    received++;
  }
  await _saveState(newState);
  return SyncResult(sent: upload.length, received: received, clashes: clashes, locked: locked.toList()..sort());
}
