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

/// Fråga AI: beskriv en ändring, se AI:ns förslag som diff, spara som utkast.
class AiScreen extends StatefulWidget {
  const AiScreen({super.key, this.ask = '', this.send = false, this.proposal});
  final String ask;

  /// Skicka [ask] direkt när vyn öppnas.
  final bool send;

  /// Ett färdigt förslag, för skärmbilder och tester.
  final AiProposal? proposal;

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  late final _ctl = TextEditingController(text: widget.ask);
  Map<String, String> _files = {};
  AiService _service = AiService.claude;

  /// Filerna som förslaget bygger på, så att diffen står kvar efter att utkasten sparats.
  Map<String, String> _base = {};
  bool _busy = false;
  String? _error;
  late AiProposal? _proposal = widget.proposal;
  bool _saved = false;
  bool _published = false;

  /// Posterna som en fråga från AI:n gav, räknade på telefonen.
  List<(Collection, Rec)>? _results;

  /// Förslaget man vill ändra i; nästa fråga skickas med det som utgångspunkt.
  AiProposal? _previous;
  bool _showFiles = false;
  bool _manySources = false;

  @override
  void initState() {
    super.initState();
    _load().then((_) {
      if (widget.proposal != null) _runQuery(widget.proposal!);
      if (widget.send && widget.ask.trim().isNotEmpty) _send();
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final files = await filesForAi(await allDrafts());
    final service = await aiService();
    if (mounted) {
      setState(() {
        _files = files;
        _service = service;
        if (_proposal == null || _base.isEmpty) _base = files;
      });
    }
  }

  Future<void> _send() async {
    final ask = _ctl.text.trim();
    if (ask.isEmpty) {
      setState(() => _error = 'Skriv en fråga eller en ändring först.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final prev = _previous;
      // En uppföljning skickar med förra förslaget, så att AI:n bygger vidare på det.
      final p = prev == null
          ? await askAi(ask, _files)
          : await askAi(
              'Du gav nyss det här förslaget: ${prev.summary}\n'
              'Filerna ovan innehåller redan förslaget${prev.run.isEmpty ? '' : ', och frågan som kördes är ${prev.run}'}. '
              'Svara med hela förslaget igen, med den här ändringen:\n$ask',
              {..._files, for (final f in prev.files) f.path: f.content},
            );
      if (!mounted) return;
      setState(() {
        _base = _files;
        _proposal = p;
        _previous = null;
      });
      await _runQuery(p);
    } on AiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Något gick fel: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Kör frågan som AI:n skrev, mot posterna på telefonen. Inget skickas någonstans.
  Future<void> _runQuery(AiProposal p) async {
    if (p.run.isEmpty) return;
    final ws = Workspace.fromFiles({..._base, for (final f in p.files) f.path: f.content});
    final q = ws.queries.where((q) => 'apps/${q.app}/${q.name}.query.yaml' == p.run).firstOrNull;
    if (q == null) {
      final why = ws.problems.where((x) => x.contains(p.run.split('/').last)).join('\n');
      if (mounted) setState(() => _error = 'Frågan gick inte att köra. $why'.trim());
      return;
    }
    final results = await runQuery(q, ws.collections);
    if (mounted) {
      setState(() {
        _results = results;
        _manySources = q.sources(ws.collections).length > 1;
      });
    }
  }

  /// Redigera frågan som AI:n skrev; Prova i editorn kör den, och listan här räknas om.
  Future<void> _editQuery(AiProposal p, AiFile f) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditScreen(path: f.path, text: f.content),
      ),
    );
    if (saved != true) return;
    final text = await readDraft(f.path) ?? f.content;
    final next = AiProposal(
      p.summary,
      [for (final x in p.files) x.path == f.path ? AiFile(x.path, text) : x],
      ore: p.ore,
      run: p.run,
    );
    setState(() => _proposal = next);
    await _runQuery(next);
  }

  void _reset() => setState(() {
    _previous = null;
    _showFiles = false;
    _proposal = null;
    _results = null;
    _saved = false;
    _published = false;
    _error = null;
    _ctl.clear();
  });

  Future<void> _save() async {
    final p = _proposal!;
    final before = {for (final f in p.files) f.path: await readDraft(f.path)};
    for (final f in p.files) {
      await writeDraft(f.path, f.content);
    }
    setState(() => _saved = true);
    if (!mounted) return;
    showUndo(context, 'Sparat som ${p.files.length} utkast', () async {
      for (final e in before.entries) {
        e.value == null ? await discardDraft(e.key) : await writeDraft(e.key, e.value!);
      }
      await _load();
      if (mounted) setState(() => _saved = false);
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _proposal;
    return AltPage(
      back: 'Meny',
      title: 'Fråga AI',
      bottom: _busy
          ? null
          : p == null
          ? PrimaryButton('Skicka', onTap: _send)
          : _published || p.files.isEmpty
          ? PrimaryButton('Ny fråga', onTap: _reset)
          : _saved
          ? PrimaryButton(
              'Spara till GitHub',
              onTap: () async {
                if (await publishDrafts(context, [for (final f in p.files) f.path])) {
                  setState(() => _published = true);
                }
              },
            )
          : Row(
              children: [
                Expanded(
                  child: PrimaryButton(
                    p.run.isEmpty ? 'Spara utkast' : 'Spara i menyn',
                    onTap: p.run.isEmpty
                        ? _save
                        : () async {
                            // En fråga sparas direkt till GitHub, så att den syns i menyn.
                            await _save();
                            if (!context.mounted) return;
                            if (await publishDrafts(context, [for (final f in p.files) f.path])) {
                              setState(() => _published = true);
                            }
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
                        onPressed: () => setState(() {
                          _previous = _proposal;
                          _proposal = null;
                          _results = null;
                          _ctl.clear();
                        }),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: accent,
                          side: const BorderSide(color: accent),
                          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
                        ),
                        child: const Text('Ändra', style: TextStyle(fontSize: 18)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
      child: p == null ? _askView() : _proposalView(p),
    );
  }

  Widget _askView() {
    return ListView(
      children: [
        Text(
          'Skickar ${_files.length} filer från ${defaultRepo.split('/').last} till ${_service.label} (${_service.modelName}). '
          'Dina poster skickas aldrig.',
          style: const TextStyle(color: muted, fontSize: 15),
        ),
        if (_previous != null) ...[
          const SizedBox(height: 12),
          Text('Förra förslaget: ${_previous!.summary}', style: const TextStyle(color: accent, fontSize: 15)),
          const Text(
            'Skriv vad som ska ändras, så bygger AI:n vidare på det.',
            style: TextStyle(color: muted, fontSize: 15),
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _ctl,
          enabled: !_busy,
          minLines: 4,
          maxLines: 10,
          autofocus: widget.ask.isEmpty || _previous != null,
          cursorColor: accent,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Till exempel: vilka uppgifter har jag kvar? eller: lägg till en samling för böcker jag har läst',
            hintStyle: TextStyle(color: muted, fontSize: 16),
            border: OutlineInputBorder(borderSide: BorderSide(color: line)),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: line)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: accent)),
          ),
        ),
        if (_busy) ...[
          const SizedBox(height: 20),
          const LinearProgressIndicator(color: accent, backgroundColor: line),
          const SizedBox(height: 8),
          Text('${_service.label} skriver…', style: const TextStyle(color: muted, fontSize: 15)),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_error!, style: const TextStyle(color: red)),
          ),
      ],
    );
  }

  Widget _proposalView(AiProposal p) {
    return ListView(
      children: [
        Text(
          p.summary.trim().isNotEmpty
              ? p.summary
              : p.files.isEmpty
              ? 'AI:n hade inget svar.'
              : 'Förslag på ändringar i ${p.files.length} filer.',
        ),
        if (p.ore != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'kostade ca ${p.ore! < 1 ? 'under 1' : p.ore!.round()} öre',
              style: const TextStyle(color: muted, fontSize: 15),
            ),
          ),
        if (_saved)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _published
                  ? 'Sparat till GitHub och används nu i appen.'
                  : 'Sparat som utkast. Tryck på en fil för att prova den, och spara sedan till GitHub.',
              style: const TextStyle(color: accent, fontSize: 15),
            ),
          ),
        if (_results != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 4),
            child: Text(
              _results!.length == 1 ? 'Svar: 1 post' : 'Svar: ${_results!.length} poster',
              style: const TextStyle(color: accent, fontWeight: FontWeight.w700),
            ),
          ),
          QueryResults(items: _results!, onChanged: () => _runQuery(p), showCollection: _manySources),
          if (!_saved)
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: Text(
                'Listan räknades fram på telefonen och är inte sparad. Vill du ha den som menyval trycker du Spara i menyn.',
                style: TextStyle(color: muted, fontSize: 15),
              ),
            ),
          InkWell(
            onTap: () => setState(() => _showFiles = !_showFiles),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _showFiles ? 'Dölj frågan' : 'Visa och redigera frågan ›',
                  style: const TextStyle(color: accent, fontSize: 15),
                ),
              ),
            ),
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_error!, style: const TextStyle(color: red)),
          ),
        for (final f in (p.run.isEmpty || _showFiles ? p.files : const <AiFile>[])) ...[
          const SizedBox(height: 20),
          InkWell(
            onTap: _saved
                ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FileScreen(path: f.path)))
                : f.path == p.run
                ? () => _editQuery(p, f)
                : null,
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
                        text: _base.containsKey(f.path) ? '  ändrad' : '  ny',
                        style: const TextStyle(color: muted, fontSize: 15, fontWeight: FontWeight.w400),
                      ),
                      if (!_saved && f.path == p.run)
                        const TextSpan(
                          text: '  redigera',
                          style: TextStyle(color: accent, fontSize: 15, fontWeight: FontWeight.w400),
                        ),
                      if (_saved)
                        const TextSpan(
                          text: '  ›',
                          style: TextStyle(color: accent),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          _Diff(lineDiff(_base[f.path] ?? '', f.content)),
        ],
      ],
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
