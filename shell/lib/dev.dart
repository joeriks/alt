import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'engine.dart';
import 'github.dart';
import 'host.dart';
import 'screens.dart';
import 'ui.dart';
import 'workspace.dart';

/// Utveckla: se filerna från receptrepot, redigera dem som utkast och prova
/// utkasten. Utkast ligger bara på telefonen i `drafts/` och påverkar inget
/// förrän de sparas till GitHub med [publishDrafts].

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

/// Hämtade filer och nya utkast som relativa sökvägar, sorterade.
Future<List<String>> workspaceFiles() async {
  final root = await workspaceDir();
  return {
    if (root.existsSync())
      for (final f in root.listSync(recursive: true).whereType<File>()) f.path.substring(root.path.length + 1),
    ...(await allDrafts()).keys,
  }.toList()..sort();
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
      bottom: _drafts.isEmpty
          ? null
          : PrimaryButton(
              _drafts.length == 1 ? 'Spara utkastet till GitHub' : 'Spara ${_drafts.length} utkast till GitHub',
              onTap: () async {
                await publishDrafts(context, _drafts.toList()..sort());
                await _load();
              },
            ),
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
        builder: (_) => EditScreen(path: widget.path, text: _text, publish: true),
      ),
    );
    if (changed == true) await _load();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1B18),
        title: Text('Ta bort $_name?', style: const TextStyle(fontSize: 20)),
        content: Text(
          'Filen tas bort från ${defaultRepo.split('/').last} och ur appen. '
          'Den finns kvar i historiken på GitHub om du ångrar dig.',
          style: const TextStyle(color: muted, fontSize: 15),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Avbryt')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ta bort', style: TextStyle(color: red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      if (_synced.isNotEmpty) await publishFiles({widget.path: null}, 'Tog bort $_name i appen');
      await discardDraft(widget.path);
      messenger.showSnackBar(SnackBar(content: Text('$_name borttagen'), persist: false));
      nav.pop();
    } on PublishException catch (e) {
      if (mounted) await _message(context, 'Kunde inte ta bort', e.message);
    }
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
    final lines = _text.endsWith('\n') ? _text.substring(0, _text.length - 1).split('\n') : _text.split('\n');
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
                  onPressed: () async {
                    if (await publishDrafts(context, [widget.path])) await _load();
                  },
                  child: const Text('spara', style: TextStyle(color: accent)),
                ),
                TextButton(
                  onPressed: _discard,
                  child: const Text('kasta', style: TextStyle(color: muted)),
                ),
              ],
            ),
          if (_draft == null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _delete,
                child: const Text('ta bort', style: TextStyle(color: muted)),
              ),
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
  const EditScreen({super.key, required this.path, required this.text, this.publish = false});
  final String path;
  final String text;

  /// Spara går direkt till GitHub (efter kontroll och bekräftelse); "bara utkast" finns som sidoval.
  final bool publish;

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

  Future<void> _publish() async {
    await writeDraft(widget.path, _ctl.text);
    if (!mounted) return;
    if (await publishDrafts(context, [widget.path]) && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AltPage(
      back: widget.path.split('/').last,
      title: 'Redigera',
      bottom: Row(
        children: [
          Expanded(
            child: widget.publish
                ? PrimaryButton('Spara', onTap: _publish)
                : PrimaryButton('Spara utkast', onTap: _save),
          ),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.publish)
            InkWell(
              onTap: _save,
              child: const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('bara utkast ›', style: TextStyle(color: muted, fontSize: 15)),
              ),
            ),
          Expanded(child: _field()),
        ],
      ),
    );
  }

  Widget _field() {
    return TextField(
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
    if (path.endsWith('.query.yaml') && hit.isEmpty) {
      final name = path.split('/').last.replaceAll('.query.yaml', '');
      final q = ws.queries.where((q) => q.name == name).firstOrNull;
      if (q != null && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => QueryScreen(query: q, collections: ws.collections, back: 'Utkast'),
          ),
        );
        return;
      }
    }
    if (path.endsWith('.report.md') && hit.isEmpty) {
      final name = path.split('/').last.replaceAll('.report.md', '');
      final r = ws.reports.where((r) => r.name == name).firstOrNull;
      if (r != null && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ReportScreen(report: r, collections: ws.collections),
          ),
        );
        return;
      }
    }
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

/// Sparar utkasten för [paths] till receptrepot, efter en kontroll och en bekräftelse.
/// Returnerar true om de sparades.
Future<bool> publishDrafts(BuildContext context, List<String> paths) async {
  final drafts = await allDrafts();
  final files = {
    for (final p in paths)
      if (drafts.containsKey(p)) p: drafts[p]!,
  };
  if (files.isEmpty || !context.mounted) return false;
  final ws = await Workspace.load(overlay: drafts);
  final problems = [
    for (final pr in ws.problems)
      if (files.keys.any((p) => pr.contains(p.split('/').last) || (p.startsWith('lang/') && pr.startsWith('lang')))) pr,
  ];
  if (!context.mounted) return false;
  if (problems.isNotEmpty) {
    await _message(context, 'Rätta det här först', problems.join('\n\n'));
    return false;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1B18),
      title: const Text('Spara till GitHub?', style: TextStyle(fontSize: 20)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ändringen hamnar i ${defaultRepo.split('/').last} och börjar gälla i appen. '
            'Den gamla versionen finns kvar i historiken på GitHub.',
            style: const TextStyle(color: muted, fontSize: 15),
          ),
          const SizedBox(height: 12),
          for (final p in files.keys) Text(p, style: _code),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Avbryt')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Spara')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('Sparar till GitHub…'), duration: Duration(minutes: 1)));
  try {
    final names = files.keys.map((p) => p.split('/').last).join(', ');
    final sha = await publishFiles(files, 'Ändrat i appen: $names');
    for (final p in files.keys) {
      await discardDraft(p);
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Sparat till GitHub ($sha)'), persist: false));
    return true;
  } on PublishException catch (e) {
    messenger.hideCurrentSnackBar();
    if (context.mounted) await _message(context, 'Kunde inte spara', e.message);
    return false;
  }
}

Future<void> _message(BuildContext context, String title, String body) => showModalBottomSheet(
  context: context,
  backgroundColor: const Color(0xFF1A1B18),
  builder: (ctx) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: red),
          ),
          const SizedBox(height: 12),
          Text(body),
        ],
      ),
    ),
  ),
);

/// Skapar en ny fråga: välj app och namn, skriv frågan och prova den innan den sparas.
Future<void> newQuery(BuildContext context) async {
  final ws = await Workspace.load();
  final apps = <String, String>{for (final c in ws.collections) c.app: c.appLabel};
  if (apps.isEmpty || !context.mounted) return;
  var app = apps.keys.first;
  final ctl = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: const Color(0xFF1A1B18),
        title: const Text('Ny fråga', style: TextStyle(fontSize: 20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (apps.length > 1)
              Wrap(
                spacing: 8,
                children: [
                  for (final e in apps.entries)
                    ChoiceChip(
                      label: Text(e.value),
                      selected: app == e.key,
                      onSelected: (_) => setState(() => app = e.key),
                    ),
                ],
              ),
            TextField(
              controller: ctl,
              autofocus: true,
              cursorColor: accent,
              decoration: const InputDecoration(hintText: 'namn, t.ex. open_tasks'),
            ),
            if (error != null) Text(error!, style: const TextStyle(color: red, fontSize: 15)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Avbryt')),
          TextButton(
            onPressed: () {
              if (!RegExp(r'^[a-zåäö][a-zåäö0-9_]*$').hasMatch(ctl.text.trim())) {
                setState(() => error = 'Små bokstäver, siffror och _, börja med en bokstav.');
              } else {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('Skapa'),
          ),
        ],
      ),
    ),
  );
  final name = ctl.text.trim();
  ctl.dispose();
  if (ok != true || !context.mounted) return;
  final first = ws.collections.firstWhere((c) => c.app == app);
  final template = [
    'label: ${name[0].toUpperCase()}${name.substring(1).replaceAll('_', ' ')}',
    'from: ${first.name}',
    'where:',
    if (first.fields.any((f) => f.type == 'bool'))
      '  ${first.fields.firstWhere((f) => f.type == 'bool').name}: false'
    else
      '  # ${first.titleField}: { contains: text }',
    if (first.dateField != null) '  ${first.dateField!.name}: { from: today, to: today+14d }',
    if (first.dateField != null) 'sort: ${first.dateField!.name}',
    '',
  ].join('\n');
  final path = 'apps/$app/$name.query.yaml';
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => EditScreen(path: path, text: template, publish: true),
    ),
  );
  // Efter sparat utkast: visa filen, där man kan prova den igen och spara till GitHub.
  if (saved == true && context.mounted) {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => FileScreen(path: path)));
  }
}
