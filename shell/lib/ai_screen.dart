import 'package:flutter/material.dart';

import 'ai.dart';
import 'dev.dart';
import 'ui.dart';
import 'workspace.dart';

const _code = TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.45, color: fg);
const _green = Color(0xFF9CC57A);

/// Fråga AI: beskriv en ändring, se AI:ns förslag som diff, spara som utkast.
class AiScreen extends StatefulWidget {
  const AiScreen({super.key, this.ask = '', this.proposal});
  final String ask;

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

  @override
  void initState() {
    super.initState();
    _load();
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
      setState(() => _error = 'Skriv vad du vill ändra först.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await askAi(ask, _files);
      if (!mounted) return;
      setState(() {
        _base = _files;
        _proposal = p;
        _error = p.files.isEmpty ? 'AI:n föreslog inga ändringar. ${p.summary}'.trim() : null;
        if (p.files.isEmpty) _proposal = null;
      });
    } on AiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Något gick fel: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
          : _published
          ? PrimaryButton(
              'Nytt förslag',
              onTap: () => setState(() {
                _proposal = null;
                _saved = false;
                _published = false;
                _ctl.clear();
              }),
            )
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
                Expanded(child: PrimaryButton('Spara utkast', onTap: _save)),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SizedBox(
                      height: 56,
                      child: OutlinedButton(
                        onPressed: () => setState(() => _proposal = null),
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
        const SizedBox(height: 16),
        TextField(
          controller: _ctl,
          enabled: !_busy,
          minLines: 4,
          maxLines: 10,
          autofocus: widget.ask.isEmpty,
          cursorColor: accent,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Till exempel: lägg till en samling för böcker jag har läst, med betyg',
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
        Text(p.summary.trim().isEmpty ? 'Förslag på ändringar i ${p.files.length} filer.' : p.summary),
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
        for (final f in p.files) ...[
          const SizedBox(height: 20),
          InkWell(
            onTap: _saved
                ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FileScreen(path: f.path)))
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
