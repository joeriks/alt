import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'sync.dart';
import 'ui.dart';
import 'workspace.dart';

/// Guiden System / Koppla GitHub: två repon, en nyckel och en kontroll av att allt fungerar.

const _secure = FlutterSecureStorage();
const newRepoUrl = 'https://github.com/new';
const newTokenUrl = 'https://github.com/settings/personal-access-tokens/new';

Future<bool> setupSeen() async => (await _secure.read(key: 'setup_seen')) != null;
Future<void> markSetupSeen() => _secure.write(key: 'setup_seen', value: '1');

/// Ett steg i kontrollen: vad som provades, om det gick, och vad man gör åt det.
class Check {
  Check(this.label, this.ok, [this.fix = '', this.warning = false]);
  final String label;
  final bool ok;
  final String fix;

  /// Inte ett fel, men värt att veta.
  final bool warning;
}

typedef GitHubGet = Future<(int, dynamic)> Function(String method, String path, [Object? body]);

GitHubGet gitHubCaller(String token) => (method, path, [body]) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse('https://api.github.com$path'));
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.set('Accept', 'application/vnd.github+json');
    req.headers.set('X-GitHub-Api-Version', '2022-11-28');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await res.transform(utf8.decoder).join();
    dynamic json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {}
    return (res.statusCode, json);
  } finally {
    client.close();
  }
};

/// Provar nyckeln mot båda repona. Skriver inget som syns: skrivrätten provas med en lös blob,
/// som git inte visar och städar bort själv.
Future<List<Check>> checkGitHub(GitHubGet call, String recipes, String data) async {
  final out = <Check>[];
  final (s, user) = await call('GET', '/user');
  if (s == 401) {
    return [Check('Nyckeln', false, 'GitHub känner inte igen nyckeln. Kopiera den igen, hela, eller skapa en ny.')];
  }
  if (s != 200) return [Check('Nyckeln', false, 'GitHub svarade $s. Försök igen om en stund.')];
  out.add(Check('Nyckeln tillhör ${user['login']}', true));

  Future<void> repo(String name, String role, {required bool mustBePrivate}) async {
    final (s, info) = await call('GET', '/repos/$name');
    if (s == 404) {
      out.add(
        Check(
          '$role: $name',
          false,
          'Nyckeln hittar inte repot. Kontrollera stavningen, eller redigera nyckeln på GitHub och lägg till '
              '${name.split('/').last} under Repository access.',
        ),
      );
      return;
    }
    if (s != 200) {
      out.add(Check('$role: $name', false, 'GitHub svarade $s.'));
      return;
    }
    out.add(Check('$role: $name hittades', true));
    if (mustBePrivate && info['private'] != true) {
      out.add(
        Check(
          '$role är publikt',
          false,
          'Alla kan läsa dina poster. Gör repot privat på GitHub under Settings / Danger Zone / Change visibility.',
        ),
      );
    }
    final (w, _) = await call('POST', '/repos/$name/git/blobs', {'content': '', 'encoding': 'utf-8'});
    if (w == 201) {
      out.add(Check('$role: nyckeln får skriva', true));
    } else if (w == 409) {
      out.add(Check('$role är tomt', true, 'Det fylls på när appen sparar första gången.', true));
    } else {
      out.add(
        Check(
          '$role: nyckeln får inte skriva',
          false,
          'Redigera nyckeln på GitHub. Under Permissions / Repository permissions, sätt Contents till Read and write.',
        ),
      );
    }
  }

  await repo(recipes, 'Receptrepot', mustBePrivate: false);
  await repo(data, 'Datarepot', mustBePrivate: true);
  return out;
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, this.back = 'Meny', this.start = 0, this.checks});
  final String back;
  final int start;

  /// Färdigt resultat av kontrollen, för skärmbilder.
  final List<Check>? checks;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late int _step = widget.start;
  final _recipes = TextEditingController(text: defaultRepo);
  final _data = TextEditingController(text: defaultDataRepo);
  final _token = TextEditingController();
  bool _hasToken = false;
  List<Check>? _checks;
  bool _busy = false;
  String? _done;

  @override
  void initState() {
    super.initState();
    _checks = widget.checks;
    () async {
      final r = await recipesRepo(), d = await dataRepo(), t = await githubToken();
      if (!mounted) return;
      setState(() {
        _recipes.text = r;
        _data.text = d;
        _hasToken = (t ?? '').isNotEmpty;
      });
    }();
  }

  @override
  void dispose() {
    _recipes.dispose();
    _data.dispose();
    _token.dispose();
    super.dispose();
  }

  String _clean(String s) =>
      s.trim().replaceFirst(RegExp(r'^https?://github\.com/'), '').replaceAll(RegExp(r'(\.git)?/*$'), '');

  Future<void> _check() async {
    setState(() {
      _step = 2;
      _busy = true;
      _checks = null;
      _done = null;
    });
    final recipes = _clean(_recipes.text), data = _clean(_data.text);
    await _secure.write(key: 'recipes_repo', value: recipes);
    await _secure.write(key: 'data_repo', value: data);
    if (_token.text.trim().isNotEmpty) await setGithubToken(_token.text);
    final token = await githubToken();
    List<Check> checks;
    try {
      checks = (token ?? '').isEmpty
          ? [Check('Nyckeln', false, 'Ingen nyckel inlagd. Gå tillbaka ett steg och klistra in den.')]
          : await checkGitHub(gitHubCaller(token!), recipes, data);
    } on SocketException {
      checks = [Check('Kontakt med GitHub', false, 'Ingen kontakt. Är du ansluten till internet?')];
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _checks = checks;
      _hasToken = (token ?? '').isNotEmpty;
    });
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    await markSetupSeen();
    final parts = <String>[];
    try {
      parts.add('hämtade ${await syncWorkspace()} receptfiler');
    } catch (e) {
      parts.add('recepten: $e');
    }
    try {
      parts.add('poster: ${(await syncData()).summary}');
    } catch (e) {
      parts.add('posterna: $e');
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _done = parts.join('\n');
      });
    }
  }

  Widget _link(String text, String url) => InkWell(
    onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(text, style: const TextStyle(color: accent)),
    ),
  );

  Widget _button(String text, VoidCallback? onTap) => TextButton(
    onPressed: onTap,
    child: Text(text, style: TextStyle(color: onTap == null ? muted : accent, fontSize: 18)),
  );

  Widget _numbered(List<String> lines) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < lines.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 26,
                child: Text('${i + 1}.', style: const TextStyle(color: muted)),
              ),
              Expanded(child: Text(lines[i], style: const TextStyle(fontSize: 16))),
            ],
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    const help = TextStyle(color: muted, fontSize: 15);
    final steps = <Widget>[
      // 1. Repona
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'alt använder två repon på GitHub: ett för appens recept och samlingar, och ett privat för dina poster. '
            'Skapa dem först om du inte har dem.',
            style: help,
          ),
          _link('Skapa ett repo på GitHub ›', newRepoUrl),
          _numbered([
            'Välj Private.',
            'Kryssa i Add a README, så att repot inte är tomt.',
            'Gör likadant för det andra repot.',
          ]),
          const SizedBox(height: 12),
          const Text('Receptrepo', style: help),
          TextField(controller: _recipes, cursorColor: accent, autocorrect: false),
          const SizedBox(height: 16),
          const Text('Datarepo (privat)', style: help),
          TextField(controller: _data, cursorColor: accent, autocorrect: false),
          const SizedBox(height: 4),
          const Text('Skriv ägare/namn, eller klistra in adressen till repot.', style: help),
          const SizedBox(height: 20),
          _button('Nästa: nyckel ›', () => setState(() => _step = 1)),
        ],
      ),
      // 2. Nyckeln
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Appen behöver en nyckel som bara gäller de två repona. Den sparas krypterad på telefonen.',
            style: help,
          ),
          _link('Skapa en nyckel på GitHub ›', newTokenUrl),
          _numbered([
            'Token name: alt.',
            'Expiration: välj hur länge den ska gälla, till exempel ett år.',
            'Repository access: Only select repositories, och välj ${_clean(_recipes.text).split('/').last} '
                'och ${_clean(_data.text).split('/').last}.',
            'Permissions: lägg till Contents och välj Read and write.',
            'Tryck Generate token och kopiera nyckeln.',
          ]),
          const SizedBox(height: 8),
          Text(
            _hasToken
                ? 'Klistra in en ny nyckel, eller lämna tomt för att behålla den du har.'
                : 'Klistra in nyckeln här',
            style: help,
          ),
          TextField(
            controller: _token,
            cursorColor: accent,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(hintText: 'github_pat_…'),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            children: [_button('‹ Tillbaka', () => setState(() => _step = 0)), _button('Kontrollera ›', _check)],
          ),
        ],
      ),
      // 3. Kontrollen
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_busy && _checks == null) ...[
            const LinearProgressIndicator(color: accent, backgroundColor: line),
            const SizedBox(height: 8),
            const Text('Provar nyckeln mot GitHub…', style: help),
          ],
          for (final c in _checks ?? const <Check>[])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 26,
                    child: Text(
                      c.ok ? '✓' : '✗',
                      style: TextStyle(color: c.ok ? (c.warning ? muted : const Color(0xFF9CC57A)) : red),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.label, style: const TextStyle(fontSize: 16)),
                        if (c.fix.isNotEmpty) Text(c.fix, style: help),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (_checks != null && _done == null) ...[
            const SizedBox(height: 8),
            if (_checks!.every((c) => c.ok))
              _button(_busy ? 'Hämtar…' : 'Klart, hämta recept och poster ›', _busy ? null : _finish)
            else ...[
              const Text('Rätta det som är rött på GitHub och prova igen.', style: help),
              if (_checks!.any((c) => !c.ok && c.fix.toLowerCase().contains('nyckeln på github')))
                _link('Öppna dina nycklar på GitHub ›', 'https://github.com/settings/personal-access-tokens'),
              Wrap(
                spacing: 12,
                children: [_button('‹ Tillbaka', () => setState(() => _step = 1)), _button('Prova igen', _check)],
              ),
            ],
          ],
          if (_done != null) ...[
            Text(_done!, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 16),
            _button('Till menyn', () => Navigator.of(context).pop()),
          ],
        ],
      ),
    ];
    const titles = ['Repon', 'Nyckel', 'Kontroll'];
    return AltPage(
      back: widget.back,
      title: 'Koppla GitHub',
      child: ListView(
        children: [
          Text(
            [for (var i = 0; i < 3; i++) i == _step ? '[${i + 1} ${titles[i]}]' : '${i + 1} ${titles[i]}'].join('  '),
            style: const TextStyle(color: accent, fontSize: 15),
          ),
          const SizedBox(height: 16),
          steps[_step],
        ],
      ),
    );
  }
}
