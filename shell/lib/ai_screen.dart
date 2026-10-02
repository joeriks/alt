import 'package:flutter/material.dart';

import 'ai.dart';
import 'dev.dart';
import 'query.dart';
import 'records.dart';
import 'screens.dart';
import 'ui.dart';
import 'workspace.dart';

const _code = TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.45, color: fg);
const _green = Color(0xFF9CC57A);
const _small = TextStyle(color: muted, fontSize: 14);
const _action = TextStyle(color: accent, fontSize: 14);

/// En växling i samtalet: det du skrev och AI:ns svar.
class _Turn {
  _Turn(this.ask);
  final String ask;
  AiProposal? proposal;
  String? error;
  bool busy = true;

  /// Posterna som AI:ns fråga gav, räknade på telefonen.
  List<(Collection, Rec)>? results;
  String? label;
  bool manySources = false;
  bool published = false;
}

/// Fråga AI som en chatt: fråga om dina poster, be om ändringar och ställ följdfrågor.
/// Att spara eller ändra filer är ett sidospår vid varje svar.
class AiScreen extends StatefulWidget {
  const AiScreen({super.key, this.ask = '', this.send = false, this.proposal});
  final String ask;

  /// Skicka [ask] direkt när vyn öppnas.
  final bool send;

  /// Ett färdigt svar på [ask], för skärmbilder och tester.
  final AiProposal? proposal;

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  final _ctl = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <_Turn>[];

  /// Receptrepots filer med utkast ovanpå.
  Map<String, String> _files = {};
  AiService _service = AiService.claude;

  @override
  void initState() {
    super.initState();
    _load().then((_) async {
      if (widget.proposal != null) {
        final t = _Turn(widget.ask)
          ..proposal = widget.proposal
          ..busy = false;
        setState(() => _turns.add(t));
        await _runQuery(t);
      } else if (widget.send && widget.ask.trim().isNotEmpty) {
        _send(widget.ask);
      } else {
        _ctl.text = widget.ask;
      }
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final files = await filesForAi(await allDrafts());
    final service = await aiService();
    if (mounted) {
      setState(() {
        _files = files;
        _service = service;
      });
    }
  }

  /// Filerna som AI:n ser: repot, utkasten och allt den föreslagit tidigare i samtalet.
  Map<String, String> get _context => {
    ..._files,
    for (final t in _turns)
      if (t.proposal != null)
        for (final f in t.proposal!.files) f.path: f.content,
  };

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  });

  Future<void> _send([String? text]) async {
    final ask = (text ?? _ctl.text).trim();
    if (ask.isEmpty) return;
    _ctl.clear();
    final history = [
      for (final t in _turns)
        if (t.proposal != null) (ask: t.ask, summary: t.proposal!.summary),
    ];
    final files = _context;
    final t = _Turn(ask);
    setState(() => _turns.add(t));
    _toBottom();
    try {
      t.proposal = await askAi(ask, files, history: history);
      await _runQuery(t);
    } on AiException catch (e) {
      t.error = e.message;
    } catch (e) {
      t.error = 'Något gick fel: $e';
    }
    if (!mounted) return;
    setState(() => t.busy = false);
    _toBottom();
  }

  /// Kör frågan som AI:n skrev, mot posterna på telefonen. Inget skickas någonstans.
  Future<void> _runQuery(_Turn t) async {
    final p = t.proposal;
    if (p == null || p.run.isEmpty) return;
    final ws = Workspace.fromFiles({..._context, for (final f in p.files) f.path: f.content});
    final q = ws.queries.where((q) => 'apps/${q.app}/${q.name}.query.yaml' == p.run).firstOrNull;
    if (q == null) {
      t.error = 'Frågan gick inte att köra. ${ws.problems.where((x) => x.contains(p.run.split('/').last)).join('\n')}'
          .trim();
      return;
    }
    final results = await runQuery(q, ws.collections);
    if (!mounted) return;
    setState(() {
      t.results = results;
      t.label = q.label;
      t.manySources = q.sources(ws.collections).length > 1;
    });
  }

  /// Sparar svarets filer till GitHub, via utkast. För en fråga blir det ett menyval.
  Future<void> _publish(_Turn t, [AiProposal? edited]) async {
    if (edited != null) setState(() => t.proposal = edited);
    final p = t.proposal!;
    for (final f in p.files) {
      await writeDraft(f.path, f.content);
    }
    if (!mounted) return;
    if (await publishDrafts(context, [for (final f in p.files) f.path])) {
      setState(() => t.published = true);
    }
    await _load();
  }

  Future<void> _openFiles(_Turn t) async {
    final edited = await Navigator.of(context).push<AiProposal>(
      MaterialPageRoute(
        builder: (_) => _ProposalScreen(proposal: t.proposal!, base: _files, onPublish: (p) => _publish(t, p)),
      ),
    );
    if (edited != null && mounted) {
      setState(() => t.proposal = edited);
      await _runQuery(t);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AltPage(
      back: 'Meny',
      title: 'Fråga AI',
      bottom: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Text('> ', style: TextStyle(color: accent, fontSize: 20)),
            ),
            Expanded(
              child: TextField(
                controller: _ctl,
                autofocus: widget.ask.isEmpty && widget.proposal == null,
                minLines: 1,
                maxLines: 5,
                cursorColor: accent,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: const TextStyle(fontSize: 18, color: fg),
                decoration: InputDecoration(
                  hintText: _turns.isEmpty ? 'fråga eller be om en ändring' : 'följdfråga',
                  hintStyle: const TextStyle(color: muted, fontSize: 18),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            IconButton(
              onPressed: _send,
              icon: const Icon(Icons.arrow_upward, color: accent),
              tooltip: 'Skicka',
            ),
          ],
        ),
      ),
      child: ListView(
        controller: _scroll,
        children: [
          if (_turns.isEmpty)
            Text(
              'Fråga om dina poster, till exempel "vad har jag i morgon?", eller be om en ändring. '
              'Filerna från ${defaultRepo.split('/').last} skickas till ${_service.label} (${_service.modelName}), '
              'men dina poster skickas aldrig: listor räknas fram på telefonen.',
              style: _small,
            ),
          for (final t in _turns) _turn(t),
        ],
      ),
    );
  }

  Widget _turn(_Turn t) {
    final p = t.proposal;
    final results = t.results;
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('> ${t.ask}', style: _small.copyWith(color: fg)),
          if (t.busy)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const LinearProgressIndicator(color: accent, backgroundColor: line),
                  const SizedBox(height: 6),
                  Text('${_service.label} skriver…', style: _small),
                ],
              ),
            ),
          if (p != null) ...[
            if (p.summary.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(p.summary, style: results == null && p.files.isEmpty ? null : _small),
              ),
            if (results != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 2),
                child: Text(
                  '${t.label ?? 'Svar'} · ${results.length == 1 ? '1 post' : '${results.length} poster'}',
                  style: const TextStyle(color: accent, fontWeight: FontWeight.w700),
                ),
              ),
              QueryResults(items: results, onChanged: () => _runQuery(t), showCollection: t.manySources),
            ],
            if (p.files.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 20,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (t.published)
                      Text(results != null ? 'sparad i menyn' : 'sparad på GitHub', style: _small)
                    else if (results != null)
                      _link('Spara i menyn', () => _publish(t))
                    else
                      _link('Visa ändringen ›', () => _openFiles(t)),
                    if (results != null) _link('Visa frågan ›', () => _openFiles(t)),
                    if (p.ore != null) Text('ca ${p.ore! < 1 ? 'under 1' : p.ore!.round()} öre', style: _small),
                  ],
                ),
              )
            else if (p.ore != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('ca ${p.ore! < 1 ? 'under 1' : p.ore!.round()} öre', style: _small),
              ),
          ],
          if (t.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t.error!, style: const TextStyle(color: red)),
            ),
        ],
      ),
    );
  }

  Widget _link(String text, VoidCallback onTap) => InkWell(
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Align(widthFactor: 1, child: Text(text, style: _action)),
    ),
  );
}

/// Filerna i ett svar som diff, med redigering av frågan och sparande till GitHub.
/// Returnerar det ändrade förslaget om något redigerades.
class _ProposalScreen extends StatefulWidget {
  const _ProposalScreen({required this.proposal, required this.base, required this.onPublish});
  final AiProposal proposal;
  final Map<String, String> base;
  final Future<void> Function(AiProposal) onPublish;

  @override
  State<_ProposalScreen> createState() => _ProposalScreenState();
}

class _ProposalScreenState extends State<_ProposalScreen> {
  late AiProposal _p = widget.proposal;
  bool _edited = false;
  bool _saved = false;

  Future<void> _edit(AiFile f) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditScreen(path: f.path, text: f.content),
      ),
    );
    if (saved != true) return;
    final text = await readDraft(f.path) ?? f.content;
    setState(() {
      _p = AiProposal(
        _p.summary,
        [for (final x in _p.files) x.path == f.path ? AiFile(x.path, text) : x],
        ore: _p.ore,
        run: _p.run,
      );
      _edited = true;
    });
  }

  Future<void> _saveDrafts() async {
    final before = {for (final f in _p.files) f.path: await readDraft(f.path)};
    for (final f in _p.files) {
      await writeDraft(f.path, f.content);
    }
    if (!mounted) return;
    setState(() => _saved = true);
    showUndo(context, 'Sparat som ${_p.files.length} utkast', () async {
      for (final e in before.entries) {
        e.value == null ? await discardDraft(e.key) : await writeDraft(e.key, e.value!);
      }
      if (mounted) setState(() => _saved = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_edited ? _p : null);
      },
      child: AltPage(
        back: 'Fråga AI',
        title: _p.run.isEmpty ? 'Ändringen' : 'Frågan',
        bottom: Row(
          children: [
            Expanded(
              child: PrimaryButton(
                'Spara',
                onTap: () async {
                  await widget.onPublish(_p);
                  if (context.mounted) Navigator.of(context).pop(_edited ? _p : null);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: _saved ? null : _saveDrafts,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: accent,
                      side: const BorderSide(color: accent),
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
                    ),
                    child: Text(_saved ? 'Utkast sparat' : 'Bara utkast', style: const TextStyle(fontSize: 18)),
                  ),
                ),
              ),
            ),
          ],
        ),
        child: ListView(
          children: [
            Text(
              'Spara lägger ändringen på GitHub och den börjar gälla i appen. Ett utkast kan du först prova under Utveckla / Filer.',
              style: _small,
            ),
            for (final f in _p.files) ...[
              const SizedBox(height: 20),
              InkWell(
                onTap: () => _edit(f),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text.rich(
                      TextSpan(
                        text: f.path,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                        children: [
                          TextSpan(
                            text: widget.base.containsKey(f.path) ? '  ändrad' : '  ny',
                            style: const TextStyle(color: muted, fontSize: 15, fontWeight: FontWeight.w400),
                          ),
                          const TextSpan(
                            text: '  redigera',
                            style: TextStyle(color: accent, fontSize: 15, fontWeight: FontWeight.w400),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _Diff(lineDiff(widget.base[f.path] ?? '', f.content)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Visar en raddiff och döljer långa oförändrade partier.
class _Diff extends StatelessWidget {
  const _Diff(this.lines);
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final show = List.filled(lines.length, false);
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith(' ')) {
        for (var j = i - 2; j <= i + 2; j++) {
          if (j >= 0 && j < lines.length) show[j] = true;
        }
      }
    }
    final spans = <TextSpan>[];
    var gap = false;
    for (var i = 0; i < lines.length; i++) {
      if (!show[i]) {
        if (!gap) {
          spans.add(
            TextSpan(
              text: '  …\n',
              style: _code.copyWith(color: muted),
            ),
          );
        }
        gap = true;
        continue;
      }
      gap = false;
      final l = lines[i];
      final color = l.startsWith('+')
          ? _green
          : l.startsWith('-')
          ? red
          : muted;
      spans.add(
        TextSpan(
          text: '$l\n',
          style: _code.copyWith(color: color),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SelectableText.rich(TextSpan(children: spans)),
    );
  }
}
