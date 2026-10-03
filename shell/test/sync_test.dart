import 'dart:convert';
import 'dart:io';

import 'package:alt/github.dart';
import 'package:alt/records.dart';
import 'package:alt/sync.dart';
import 'package:alt/workspace.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Paths extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  _Paths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// Ett datarepo i minnet.
class _Repo implements DataRemote {
  final files = <String, String>{};
  int commits = 0;
  String? get head => commits == 0 ? null : 'c$commits';

  @override
  Future<({String head, Map<String, String> files})?> snapshot() async => head == null
      ? null
      : (head: head!, files: {for (final e in files.entries) e.key: gitBlobSha(utf8.encode(e.value))});

  @override
  Future<String> read(String sha) async => files.values.firstWhere((v) => gitBlobSha(utf8.encode(v)) == sha);

  @override
  Future<void> commit(String? base, Map<String, String?> changes, String message) async {
    if (base != head) throw SyncConflict();
    for (final e in changes.entries) {
      e.value == null ? files.remove(e.key) : files[e.key] = e.value!;
    }
    commits++;
  }
}

Directory _phone() {
  final d = Directory.systemTemp.createTempSync('alt_sync');
  for (final f in Directory('test/fixture').listSync(recursive: true).whereType<File>()) {
    final t = File('${d.path}/workspace/${f.path.substring('test/fixture/'.length)}');
    t.parent.createSync(recursive: true);
    f.copySync(t.path);
  }
  File(
    '${d.path}/workspace/apps/memory_bank/notes.collection.yaml',
  ).writeAsStringSync('label: Notes\nencrypted: false\ntitle: title\nfields:\n  title: { text, required }\n');
  return d;
}

void use(Directory phone) => PathProviderPlatform.instance = _Paths(phone.path);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('kryptering går fram och tillbaka och avslöjar inte id', () async {
    final key = List.generate(32, (i) => i);
    final enc = await encryptText('hemligt', key);
    expect(enc, isNot(contains('hemligt')));
    expect(await decryptText(enc, key), 'hemligt');
    expect(() => decryptText(enc, List.generate(32, (i) => i + 1)), throwsA(isA<SyncException>()));
    final name = encryptedName('private_calendar', 'tandläkare_2026_10_06', key);
    expect(name, startsWith('private_calendar/'));
    expect(name, isNot(contains('tandläkare')));
    expect(encryptedName('private_calendar', 'tandläkare_2026_10_06', key), name);
  });

  test('två telefoner synkar via datarepot', () async {
    final repo = _Repo();
    final a = _phone(), b = _phone();
    Map<String, Collection> ws(Workspace w) => {for (final c in w.collections) c.name: c};

    // Telefon A: en okrypterad anteckning synkas direkt, kalendern väntar på lösenfras.
    use(a);
    var c = ws(await Workspace.load());
    final note = await saveRecord(c['notes']!, {'title': 'Handla'});
    final tooth = await saveRecord(c['private_calendar']!, {'title': 'Tandläkare', 'date': '2026-10-06'});
    var r = await syncData(remote: repo);
    expect(r.locked, ['private_calendar']);
    expect(repo.files.keys.where((p) => p.endsWith('.yaml')), ['notes/${note.id}.yaml']);
    // Översikterna skrivs i samma commit; den krypterade kalendern får ingen.
    expect(repo.files['notes/README.md'], contains('[Handla](${note.id}.yaml)'));
    expect(repo.files['README.md'], contains('Private calendar (krypterad)'));
    expect(repo.files.keys, isNot(contains('private_calendar/README.md')));
    expect(repo.commits, 1);

    await setPassphrase('korrekt häst batteri', remote: repo);
    r = await syncData(remote: repo);
    expect(r.sent, 1);
    final enc = repo.files.keys.where((p) => p.endsWith('.enc')).single;
    expect(repo.files[enc], isNot(contains('Tandläkare')));
    expect(repo.files.keys, contains('.alt/crypto.json'));

    // Telefon B: fel lösenfras avvisas, rätt ger alla poster.
    use(b);
    FlutterSecureStorage.setMockInitialValues({});
    await expectLater(setPassphrase('fel', remote: repo), throwsA(isA<SyncException>()));
    await setPassphrase('korrekt häst batteri', remote: repo);
    r = await syncData(remote: repo);
    expect(r.received, 2);
    expect((await readRecord('private_calendar', tooth.id))!.str('title'), 'Tandläkare');

    // B ändrar, A tar emot.
    c = ws(await Workspace.load());
    await saveRecord(c['private_calendar']!, {'title': 'Tandläkare', 'date': '2026-10-07'}, id: tooth.id);
    expect((await syncData(remote: repo)).sent, 1);
    use(a);
    r = await syncData(remote: repo);
    expect(r.received, 1);
    expect((await readRecord('private_calendar', tooth.id))!.str('date'), '2026-10-07');
    expect(await historyCount(Rec('private_calendar', tooth.id, {})), 1);

    // A tar bort anteckningen, B får den borttagen.
    await deleteRecord(note);
    await syncData(remote: repo);
    expect(repo.files.keys.where((p) => p.startsWith('notes/') && p.endsWith('.yaml')), isEmpty);
    expect(repo.files['notes/README.md'], contains('Inga poster än'));
    use(b);
    await syncData(remote: repo);
    expect(await readRecord('notes', note.id), isNull);

    // Båda ändrar samma post: krock, och valet avgör.
    c = ws(await Workspace.load());
    await saveRecord(c['private_calendar']!, {'title': 'Tandläkare B', 'date': '2026-10-07'}, id: tooth.id);
    await syncData(remote: repo);
    use(a);
    await saveRecord(c['private_calendar']!, {'title': 'Tandläkare A', 'date': '2026-10-07'}, id: tooth.id);
    r = await syncData(remote: repo);
    expect(r.clashes.single.id, tooth.id);
    expect(r.clashes.single.theirs!['title'], 'Tandläkare B');
    expect((await readRecord('private_calendar', tooth.id))!.str('title'), 'Tandläkare A');
    r = await syncData(remote: repo, resolved: {'private_calendar/${tooth.id}': true});
    expect(r.clashes, isEmpty);
    use(b);
    await syncData(remote: repo);
    expect((await readRecord('private_calendar', tooth.id))!.str('title'), 'Tandläkare A');

    // Inget att göra.
    expect((await syncData(remote: repo)).summary, 'allt är synkat');
  });
}
