import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'engine.dart';
import 'host.dart';
import 'screens.dart';
import 'ui.dart';
import 'workspace.dart';

/// Utveckla: se filerna från receptrepot, redigera dem som utkast och prova
/// utkasten. Utkast ligger bara på telefonen i `drafts/` och påverkar inget
/// förrän de sparas till GitHub (nästa steg).

Future<Directory> draftsDir() async => Directory('${(await getApplicationSupportDirectory()).path}/drafts');

Future<File> _draft(String rel) async => File('${(await draftsDir()).path}/$rel');

Future<String?> readDraft(String rel) async {
  final f = await _draft(rel);
  return f.existsSync() ? f.readAsStringSync() : null;
}

Future<void> writeDraft(String rel, String text) async {
  final f = await _draft(rel);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(text, flush: true);
}

Future<void> discardDraft(String rel) async {
  final f = await _draft(rel);
  if (f.existsSync()) f.deleteSync();
}

/// Alla utkast som relativ sökväg → text.
Future<Map<String, String>> allDrafts() async {
  final d = await draftsDir();
  if (!d.existsSync()) return {};
  return {
    for (final f in d.listSync(recursive: true).whereType<File>())
      if (!f.path.contains('/.store/')) f.path.substring(d.path.length + 1): f.readAsStringSync(),
  };
}

/// Hämtade filer som relativa sökvägar, sorterade.
Future<List<String>> workspaceFiles() async {
  final root = await workspaceDir();
  if (!root.existsSync()) return [];
  return [for (final f in root.listSync(recursive: true).whereType<File>()) f.path.substring(root.path.length + 1)]
    ..sort();
}

const _code = TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.45, color: fg);

class DevFilesScreen extends StatefulWidget {
  const DevFilesScreen({super.key});

  @override
  State<DevFilesScreen> createState() => _DevFilesScreenState();
}

class _DevFilesScreenState extends State<DevFilesScreen> {
  List<String> _files = [];
  Set<String> _drafts = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final files = await workspaceFiles();
    final drafts = (await allDrafts()).keys.toSet();
    if (mounted) {
      setState(() {
        _files = files;
        _drafts = drafts;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    String? dir;
    for (final f in _files) {
      final i = f.lastIndexOf('/');
      final d = i < 0 ? '' : f.substring(0, i);
      if (d != dir) {
        dir = d;
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text('$d/', style: const TextStyle(color: muted, fontSize: 15)),
          ),
        );
      }
      rows.add(
        InkWell(
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => FileScreen(path: f)));
            await _load();
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text.rich(
                TextSpan(
                  text: f.substring(i + 1),
                  children: [
                    if (_drafts.contains(f))
                      const TextSpan(
                        text: '  • utkast',
                        style: TextStyle(color: accent, fontSize: 15),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (rows.isEmpty) rows.add(const Text('inga filer, kör Synka / Hämta recept', style: TextStyle(color: muted)));
    return AltPage(
      back: 'Meny',
      title: 'Filer',
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: rows),
      ),
    );
  }
}

class FileScreen extends StatefulWidget {
  const FileScreen({super.key, required this.path});
  final String path;

  @override
  State<FileScreen> createState() => _FileScreenState();
}

class _FileScreenState extends State<FileScreen> {
  String _synced = '';
  String? _draft;
  List<Map<String, dynamic>> _runs = [];

  String get _name => widget.path.split('/').last;
  String get _text => _draft ?? _synced;
  bool get _isRecipe => widget.path.endsWith('.recipe');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final root = await workspaceDir();
    final f = File('${root.path}/${widget.path}');
    final synced = f.existsSync() ? f.readAsStringSync() : '';
    final draft = await readDraft(widget.path);
    var runs = <Map<String, dynamic>>[];
    if (_isRecipe) {
      try {
        final name = Recipe.parse(synced).name;
        runs = (await readRuns(limit: 200)).where((r) => r['recipe'] == name).toList();
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _synced = synced;
        _draft = draft;
        _runs = runs.length > 5 ? runs.sublist(runs.length - 5) : runs;
      });
    }
  }

  Future<void> _edit() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditScreen(path: widget.path, text: _text),
      ),
    );
    if (changed == true) await _load();
  }

  Future<void> _discard() async {
    final before = _draft!;
    await discardDraft(widget.path);
    await _load();
    if (mounted) {
      showUndo(context, 'Utkastet kastat', () async {
        await writeDraft(widget.path, before);
        await _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _text.split('\n');
    final width = '${lines.length}'.length;
    return AltPage(
      back: 'Filer',
      title: _name,
      bottom: Row(
        children: [
          Expanded(child: PrimaryButton('Prova', onTap: () => tryDraft(context, widget.path, _text))),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SizedBox(
                height: 56,
                child: OutlinedButton(
                  onPressed: _edit,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accent,
                    side: const BorderSide(color: accent),
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
                  ),
                  child: const Text('Redigera', style: TextStyle(fontSize: 18)),
                ),
              ),
            ),
          ),
        ],
      ),
      child: ListView(
        children: [
          if (_draft != null)
            Row(
              children: [
                const Expanded(
                  child: Text('utkast, inte sparat till GitHub', style: TextStyle(color: accent, fontSize: 15)),
                ),
                TextButton(
                  onPressed: _discard,
                  child: const Text('kasta', style: TextStyle(color: muted)),
                ),
              ],
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText.rich(
              TextSpan(
                children: [
                  for (var i = 0; i < lines.length; i++) ...[
                    TextSpan(
                      text: '${'${i + 1}'.padLeft(width)}  ',
                      style: _code.copyWith(color: muted),
                    ),
                    TextSpan(text: '${lines[i]}\n', style: _code),
                  ],
                ],
              ),
            ),
          ),
          if (_runs.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(top: 20, bottom: 4),
              child: Text('senaste körningar', style: TextStyle(color: muted, fontSize: 15)),
            ),
            for (final r in _runs.reversed)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${r['started'].toString().substring(11, 19)} ${r['trigger']}  '
                  '${r['ok'] == true ? 'ok' : (r['error'] ?? 'fel').toString().split('\n').first}',
                  style: TextStyle(color: r['ok'] == true ? muted : red, fontSize: 14),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class EditScreen extends StatefulWidget {
  const EditScreen({super.key, required this.path, required this.text});
  final String path;
  final String text;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  late final _ctl = TextEditingController(text: widget.text);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await writeDraft(widget.path, _ctl.text);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AltPage(
      back: widget.path.split('/').last,
      title: 'Redigera',
      bottom: Row(
        children: [
          Expanded(child: PrimaryButton('Spara utkast', onTap: _save)),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SizedBox(
                height: 56,
                child: OutlinedButton(
                  onPressed: () => tryDraft(context, widget.path, _ctl.text),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accent,
                    side: const BorderSide(color: accent),
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
                  ),
                  child: const Text('Prova', style: TextStyle(fontSize: 18)),
                ),
              ),
            ),
          ),
        ],
      ),
      child: TextField(
        controller: _ctl,
        expands: true,
        maxLines: null,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        cursorColor: accent,
        style: _code,
        decoration: const InputDecoration(border: InputBorder.none),
      ),
    );
  }
}

/// Provar en fil utan att spara något:
/// - ett recept körs mot en egen utkastlagring, och utdata visas i stället för att skickas
/// - en samling öppnar sitt formulär som förhandsvisning
/// - övriga filer (typer, språk, app.yaml) laddas om tillsammans med alla samlingar
Future<void> tryDraft(BuildContext context, String path, String text) async {
  String title;
  String body;
  var ok = true;
  if (path.endsWith('.recipe')) {
    try {
      final recipe = Recipe.parse(text);
      final store = Directory('${(await draftsDir()).path}/.store');
      final r = runRecipe(recipe, trigger: 'prova', storeDir: store);
      ok = r.ok;
      title = r.ok ? 'Körde på ${r.ms} ms' : 'Fel';
      body = [
        for (final o in r.outputs) 'skulle visa: ${o.title}\n  ${o.body}',
        for (final l in r.logs) 'log: $l',
        if (r.error != null) r.error!,
        if (r.ok && r.outputs.isEmpty && r.logs.isEmpty) 'ingen utdata',
      ].join('\n');
    } catch (e) {
      ok = false;
      title = 'Receptet går inte att läsa';
      body = '$e';
    }
  } else {
    final overlay = {...await allDrafts(), path: text};
    final ws = await Workspace.load(overlay: overlay);
    final hit = ws.problems.where((p) => p.contains(path.split('/').last)).toList();
    if (path.endsWith('.collection.yaml') && hit.isEmpty) {
      final name = path.split('/').last.replaceAll('.collection.yaml', '');
      final c = ws.collection(name);
      if (c != null && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => FormScreen(collection: c, back: 'Utkast', preview: true),
          ),
        );
        return;
      }
    }
    ok = ws.problems.isEmpty;
    title = ok ? 'Allt går att läsa' : 'Problem';
    body = ok ? '${ws.collections.length} samlingar, ${ws.recipes.length} recept' : ws.problems.join('\n\n');
  }
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF1A1B18),
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: ok ? fg : red),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
              child: SingleChildScrollView(child: SelectableText(body, style: _code)),
            ),
          ],
        ),
      ),
    ),
  );
}
