import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'ai_screen.dart';
import 'query.dart';
import 'records.dart';
import 'report.dart';
import 'ui.dart';
import 'workspace.dart';

/// Skärmarna som skalet ritar för en samling: lista, post, formulär och datumvy.

DateTime? _date(Rec r, Collection c) => c.dateField == null ? null : DateTime.tryParse(r.str(c.dateField!.name));

int _byDate(Rec a, Rec b, Collection c) {
  final da = a.str(c.dateField?.name ?? '') + a.str(c.timeField?.name ?? '');
  final db = b.str(c.dateField?.name ?? '') + b.str(c.timeField?.name ?? '');
  return da.compareTo(db);
}

/// En rad i en lista: titel, och under den datum/tid i grått.
/// Titeln på posten som ett kopplingsfält pekar på, eller id:t om posten inte finns.
Future<String> linkTitle(Collection? target, String id) async {
  if (target == null || id.isEmpty) return id;
  final r = await readRecord(target.name, id);
  return r == null ? '$id (finns inte)' : r.str(target.titleField);
}

/// Samlingar med ett kopplingsfält till [c]: deras poster är "under" en post i [c].
List<(Collection, Field)> childLinks(Workspace ws, Collection c) => [
  for (final x in ws.collections)
    for (final f in x.fields)
      if (f.type == 'link' && f.link == c.name) (x, f),
];

class _Row extends StatelessWidget {
  const _Row({required this.title, this.sub, this.dim = false, required this.onTap});

  final String title;
  final String? sub;
  final bool dim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(title, style: TextStyle(color: dim ? muted : fg)),
              if (sub != null && sub!.isNotEmpty)
                Text(
                  sub!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 15),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class CollectionScreen extends StatefulWidget {
  const CollectionScreen({super.key, required this.collection});
  final Collection collection;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  List<Rec> _recs = [];

  /// Titlar på posterna som kopplingsfälten pekar på, per fält och id.
  final _parents = <String, Map<String, String>>{};

  Collection get c => widget.collection;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final recs = await listRecords(c.name);
    if (c.dateField != null) {
      recs.sort((a, b) => _byDate(a, b, c));
    } else {
      recs.sort((a, b) => a.str(c.titleField).compareTo(b.str(c.titleField)));
    }
    final parents = <String, Map<String, String>>{};
    final links = c.fields.where((f) => f.type == 'link').toList();
    if (links.isNotEmpty) {
      final ws = await Workspace.load();
      for (final f in links) {
        final target = ws.collection(f.link!);
        if (target == null) continue;
        parents[f.name] = {for (final r in await listRecords(target.name)) r.id: r.str(target.titleField)};
      }
    }
    if (mounted) {
      setState(() {
        _recs = recs;
        _parents
          ..clear()
          ..addAll(parents);
      });
    }
  }

  String _sub(Rec r) {
    final d = _date(r, c);
    return [
      if (d != null) dayLabel(d),
      if (c.timeField != null) r.str(c.timeField!.name),
      for (final e in _parents.entries)
        if (r.str(e.key).isNotEmpty) e.value[r.str(e.key)] ?? r.str(e.key),
    ].where((s) => s.isNotEmpty).join('  ');
  }

  Future<void> _open(Rec r) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecordScreen(collection: c, rec: r),
      ),
    );
    await _load();
  }

  Future<void> _new() async {
    final saved = await Navigator.of(context).push<Rec>(
      MaterialPageRoute(
        builder: (_) => FormScreen(collection: c, back: c.label),
      ),
    );
    await _load();
    if (saved != null && mounted) {
      showUndo(context, 'Sparad: ${saved.str(c.titleField)}', () async {
        await deleteRecord(saved);
        await _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = today();
    final upcoming = <Rec>[];
    final past = <Rec>[];
    for (final r in _recs) {
      final d = _date(r, c);
      (d != null && d.isBefore(t) ? past : upcoming).add(r);
    }
    return AltPage(
      back: 'Meny',
      title: c.label,
      bottom: PrimaryButton('+ Ny', onTap: _new),
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            if (_recs.isEmpty) const Text('inga poster än', style: TextStyle(color: muted)),
            for (final r in upcoming) _Row(title: r.str(c.titleField), sub: _sub(r), onTap: () => _open(r)),
            if (past.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 24, bottom: 4),
                child: Text('tidigare', style: TextStyle(color: muted, fontSize: 15)),
              ),
            for (final r in past.reversed)
              _Row(title: r.str(c.titleField), sub: _sub(r), dim: true, onTap: () => _open(r)),
          ],
        ),
      ),
    );
  }
}

class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key, required this.collection, required this.rec, this.back});
  final Collection collection;
  final Rec rec;

  /// Vart tillbaka-pilen leder; samlingens namn om inget anges.
  final String? back;

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  late Rec _rec = widget.rec;
  int _versions = 0;
  Workspace? _ws;

  /// Titlar för kopplingsfälten, per fältnamn.
  final _linked = <String, String>{};

  /// Poster i andra samlingar som kopplar till den här, per samling och fält.
  List<(Collection, Field, List<Rec>)> _children = [];

  /// Underlistor som visas i sin helhet, per samling och fält.
  final _expanded = <String>{};
  static const _shown = 5;

  Collection get c => widget.collection;

  @override
  void initState() {
    super.initState();
    historyCount(_rec).then((n) => mounted ? setState(() => _versions = n) : null);
    _loadLinks();
  }

  Future<void> _loadLinks() async {
    final ws = _ws ?? await Workspace.load();
    final linked = <String, String>{};
    for (final f in c.fields.where((f) => f.type == 'link')) {
      final id = _rec.str(f.name);
      if (id.isNotEmpty) linked[f.name] = await linkTitle(ws.collection(f.link!), id);
    }
    final children = <(Collection, Field, List<Rec>)>[];
    for (final (x, f) in childLinks(ws, c)) {
      final recs = (await listRecords(x.name)).where((r) => r.str(f.name) == _rec.id).toList()
        ..sort(
          (a, b) => x.dateField != null
              ? _byDate(b, a, x)
              : a.str(x.titleField).toLowerCase().compareTo(b.str(x.titleField).toLowerCase()),
        );
      children.add((x, f, recs));
    }
    if (!mounted) return;
    setState(() {
      _ws = ws;
      _linked
        ..clear()
        ..addAll(linked);
      _children = children;
    });
  }

  Future<void> _openLinked(Field f) async {
    final target = _ws?.collection(f.link!);
    final r = target == null ? null : await readRecord(target.name, _rec.str(f.name));
    if (r == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecordScreen(collection: target!, rec: r, back: _rec.str(c.titleField)),
      ),
    );
    await _loadLinks();
  }

  Future<void> _openChild(Collection x, Rec r) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecordScreen(collection: x, rec: r, back: _rec.str(c.titleField)),
      ),
    );
    await _loadLinks();
  }

  Future<void> _addChild(Collection x, Field f) async {
    final saved = await Navigator.of(context).push<Rec>(
      MaterialPageRoute(
        builder: (_) => FormScreen(collection: x, back: _rec.str(c.titleField), initial: {f.name: _rec.id}),
      ),
    );
    await _loadLinks();
    if (saved == null || !mounted) return;
    showUndo(context, 'Sparad: ${saved.str(x.titleField)}', () async {
      await deleteRecord(saved);
      await _loadLinks();
    });
  }

  Future<void> _edit() async {
    final before = _rec;
    final saved = await Navigator.of(context).push<Rec>(
      MaterialPageRoute(
        builder: (_) => FormScreen(collection: c, back: before.str(c.titleField), rec: before),
      ),
    );
    if (saved == null || !mounted) return;
    setState(() => _rec = saved);
    await _loadLinks();
    _versions = await historyCount(saved);
    if (!mounted) return;
    setState(() {});
    showUndo(context, 'Ändringen sparad', () async {
      await restoreRecord(before);
      if (mounted) setState(() => _rec = before);
    });
  }

  /// Chatta med AI:n om den här posten: ändra den eller skapa en liknande.
  Future<void> _askAi() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AiScreen(rec: _rec, back: _rec.str(c.titleField)),
      ),
    );
    final now = await readRecord(_rec.collection, _rec.id);
    if (!mounted) return;
    if (now == null) {
      Navigator.of(context).pop();
      return;
    }
    _versions = await historyCount(now);
    if (mounted) setState(() => _rec = now);
  }

  /// Raden under titeln i en underlista: datum, tid, ja-fält och början av första texten.
  String _childSub(Collection x, Field link, Rec r) {
    final d = _date(r, x);
    final text = x.fields
        .where((f) => f != link && f.name != x.titleField && (f.type == 'text' || f.type == 'longtext'))
        .map((f) => r.str(f.name).replaceAll(RegExp(r'\s+'), ' ').trim())
        .firstWhere((t) => t.isNotEmpty, orElse: () => '');
    return [
      if (d != null) dayLabel(d),
      if (x.timeField != null) r.str(x.timeField!.name),
      for (final f in x.fields)
        if (f.type == 'bool' && r.values[f.name] == true) f.label.toLowerCase(),
      text,
    ].where((s) => s.isNotEmpty).join(' · ');
  }

  Future<void> _delete() async {
    final r = _rec;
    final under = _children.fold(0, (n, y) => n + y.$3.length);
    if (under > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: bg,
          title: Text('Ta bort ${r.str(c.titleField)}?'),
          content: Text(
            '$under ${under == 1 ? 'post' : 'poster'} hör till den här posten. '
            'De ligger kvar, men utan koppling.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('avbryt')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ta bort')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final messenger = ScaffoldMessenger.of(context);
    await deleteRecord(r);
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Borttagen: ${r.str(c.titleField)}'),
          duration: const Duration(seconds: 5),
          persist: false,
          action: SnackBarAction(label: 'Ångra', onPressed: () => restoreRecord(r)),
        ),
      );
  }

  Widget _childSection(Collection x, Field f, List<Rec> recs) {
    final key = '${x.name}.${f.name}';
    final all = _expanded.contains(key) || recs.length <= _shown + 1;
    final label = _children.where((y) => y.$1 == x).length > 1 ? '${x.label} (${f.label.toLowerCase()})' : x.label;
    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 8),
      padding: const EdgeInsets.only(top: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  recs.isEmpty ? label : '$label · ${recs.length}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              InkWell(
                onTap: () => _addChild(x, f),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                  child: Text('+ lägg till', style: TextStyle(color: accent, fontSize: 16)),
                ),
              ),
            ],
          ),
          if (recs.isEmpty) const Text('inga än', style: TextStyle(color: muted, fontSize: 15)),
          for (final r in all ? recs : recs.take(_shown))
            _Row(title: r.str(x.titleField), sub: _childSub(x, f, r), onTap: () => _openChild(x, r)),
          if (!all)
            InkWell(
              onTap: () => setState(() => _expanded.add(key)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text('visa alla ${recs.length} ›', style: const TextStyle(color: accent, fontSize: 16)),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AltPage(
      back: widget.back ?? c.label,
      title: _rec.str(c.titleField),
      bottom: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: line)),
        ),
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            TextButton(
              onPressed: _edit,
              child: const Text('redigera', style: TextStyle(color: accent)),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _askAi,
              child: const Text('fråga AI', style: TextStyle(color: accent)),
            ),
            const Spacer(),
            TextButton(
              onPressed: _delete,
              child: const Text('ta bort', style: TextStyle(color: muted)),
            ),
          ],
        ),
      ),
      child: ListView(
        children: [
          for (final f in c.fields)
            if (f.name != c.titleField && _rec.str(f.name).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.label, style: const TextStyle(color: muted, fontSize: 15)),
                    if (f.type == 'link')
                      InkWell(
                        onTap: () => _openLinked(f),
                        child: Text('${_linked[f.name] ?? _rec.str(f.name)} ›', style: const TextStyle(color: accent)),
                      )
                    else
                      Text(
                        f.type == 'date' && DateTime.tryParse(_rec.str(f.name)) != null
                            ? dayLabel(DateTime.parse(_rec.str(f.name)))
                            : f.type == 'bool'
                            ? (_rec.values[f.name] == true ? 'ja' : 'nej')
                            : _rec.str(f.name),
                      ),
                  ],
                ),
              ),
          // Poster som hör till den här, till exempel underområden till ett ansvarsområde.
          for (final (x, f, recs) in _children) _childSection(x, f, recs),
          if (_versions > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: Text(
                '$_versions tidigare ${_versions == 1 ? 'version' : 'versioner'}',
                style: const TextStyle(color: muted, fontSize: 15),
              ),
            ),
        ],
      ),
    );
  }
}

class FormScreen extends StatefulWidget {
  const FormScreen({
    super.key,
    required this.collection,
    required this.back,
    this.rec,
    this.initial,
    this.preview = false,
  });
  final Collection collection;

  /// Förhandsvisning från Utveckla: Spara kontrollerar fälten men sparar inget.
  final bool preview;
  final String back;
  final Rec? rec;
  final Map<String, dynamic>? initial;

  @override
  State<FormScreen> createState() => _FormScreenState();
}

class _FormScreenState extends State<FormScreen> {
  late final Map<String, dynamic> _v = {...?widget.rec?.values, ...?widget.initial};
  final Map<String, TextEditingController> _text = {};
  String? _error;

  Collection get c => widget.collection;

  @override
  void initState() {
    super.initState();
    // En ny post får dagens datum i ett obligatoriskt datumfält; det vanligaste är att man skriver in något nära i tiden.
    if (widget.rec == null) {
      for (final f in c.fields.where((f) => f.type == 'date' && f.required)) {
        _v[f.name] ??= isoDate(today());
      }
    }
    for (final f in c.fields) {
      if (f.type == 'text' || f.type == 'longtext' || f.type == 'number') {
        _text[f.name] = TextEditingController(text: _v[f.name]?.toString() ?? '');
      }
    }
    _loadLinkTitles();
  }

  @override
  void dispose() {
    for (final t in _text.values) {
      t.dispose();
    }
    super.dispose();
  }

  /// Titlar för valda kopplingar, per fältnamn.
  final _linkTitles = <String, String>{};
  Workspace? _ws;

  Future<Workspace> _workspace() async => _ws ??= await Workspace.load();

  Future<void> _loadLinkTitles() async {
    final ws = await _workspace();
    for (final f in c.fields.where((f) => f.type == 'link')) {
      final id = _v[f.name]?.toString() ?? '';
      if (id.isNotEmpty) _linkTitles[f.name] = await linkTitle(ws.collection(f.link!), id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _pickLink(Field f) async {
    final target = (await _workspace()).collection(f.link!);
    final recs = target == null ? <Rec>[] : await listRecords(target.name);
    if (target != null) {
      recs.sort((a, b) => a.str(target.titleField).toLowerCase().compareTo(b.str(target.titleField).toLowerCase()));
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<Rec?>(
      context: context,
      backgroundColor: const Color(0xFF1A1B18),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Text(f.label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (target == null)
                Text('Samlingen ${f.link} finns inte.', style: const TextStyle(color: red))
              else if (recs.isEmpty)
                Text('${target.label} har inga poster än.', style: const TextStyle(color: muted)),
              for (final r in recs) _Row(title: r.str(target!.titleField), onTap: () => Navigator.pop(ctx, r)),
              if (!f.required && (_v[f.name]?.toString() ?? '').isNotEmpty)
                _Row(title: 'ingen', dim: true, onTap: () => Navigator.pop(ctx, Rec('', '', {}))),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      if (picked.id.isEmpty) {
        _v.remove(f.name);
        _linkTitles.remove(f.name);
      } else {
        _v[f.name] = picked.id;
        _linkTitles[f.name] = picked.str(target!.titleField);
      }
    });
  }

  Future<void> _pickDate(Field f) async {
    final cur = DateTime.tryParse(_v[f.name]?.toString() ?? '') ?? today();
    final d = await showDatePicker(
      context: context,
      initialDate: cur,
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
      locale: null,
    );
    if (d != null) setState(() => _v[f.name] = isoDate(d));
  }

  Future<void> _pickTime(Field f) async {
    final parts = (_v[f.name]?.toString() ?? '').split(':');
    final cur = parts.length == 2
        ? TimeOfDay(hour: int.tryParse(parts[0]) ?? 12, minute: int.tryParse(parts[1]) ?? 0)
        : const TimeOfDay(hour: 12, minute: 0);
    final t = await showTimePicker(
      context: context,
      initialTime: cur,
      builder: (ctx, child) =>
          MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (t != null) {
      setState(() => _v[f.name] = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _save() async {
    for (final e in _text.entries) {
      final f = c.fields.firstWhere((f) => f.name == e.key);
      final s = e.value.text.trim();
      _v[e.key] = f.type == 'number' && s.isNotEmpty ? (num.tryParse(s.replaceAll(',', '.')) ?? s) : s;
    }
    final missing = c.fields.where((f) => f.required && (_v[f.name] == null || _v[f.name].toString().isEmpty));
    if (missing.isNotEmpty) {
      setState(() => _error = 'Fyll i ${missing.map((f) => f.label.toLowerCase()).join(' och ')} först.');
      return;
    }
    if (widget.preview) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Förhandsvisning: allt ifyllt rätt, inget sparades')));
      Navigator.of(context).pop();
      return;
    }
    final saved = await saveRecord(c, _v, id: widget.rec?.id);
    if (mounted) Navigator.of(context).pop(saved);
  }

  Widget _picker(Field f, String empty, VoidCallback onTap, String Function(String) show) {
    final v = _v[f.name]?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(f.label, style: const TextStyle(color: muted, fontSize: 15)),
              Text(v.isEmpty ? empty : show(v), style: TextStyle(color: v.isEmpty ? muted : fg)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AltPage(
      back: widget.back,
      title: widget.preview ? 'Förhandsvisning' : (widget.rec == null ? 'Ny' : 'Redigera'),
      bottom: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: red, fontSize: 15)),
          PrimaryButton('Spara', onTap: _save),
        ],
      ),
      child: ListView(
        children: [
          for (final f in c.fields)
            switch (f.type) {
              'date' => _picker(f, 'välj datum', () => _pickDate(f), (v) {
                final d = DateTime.tryParse(v);
                return d == null ? v : dayLabel(d);
              }),
              'time' => _picker(f, 'välj tid', () => _pickTime(f), (v) => v),
              'link' => _picker(f, 'välj…', () => _pickLink(f), (v) => _linkTitles[f.name] ?? v),
              'bool' => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(f.label),
                value: _v[f.name] == true,
                onChanged: (x) => setState(() => _v[f.name] = x == true),
              ),
              _ => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.label, style: const TextStyle(color: muted, fontSize: 15)),
                    TextField(
                      controller: _text[f.name],
                      autofocus: f.name == c.titleField && widget.rec == null,
                      minLines: f.type == 'longtext' ? 3 : 1,
                      maxLines: f.type == 'longtext' ? 8 : 1,
                      keyboardType: f.type == 'number' ? TextInputType.number : TextInputType.text,
                      textCapitalization: TextCapitalization.sentences,
                      cursorColor: accent,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ],
                ),
              ),
            },
        ],
      ),
    );
  }
}

/// Alla samlingar med `role: timeline`, de närmaste 14 dagarna, grupperat per dag.
class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key, required this.collections});
  final List<Collection> collections;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  List<(DateTime, Collection, Rec)> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = today();
    final end = t.add(const Duration(days: 14));
    final items = <(DateTime, Collection, Rec)>[];
    for (final c in widget.collections) {
      for (final r in await listRecords(c.name)) {
        final d = _date(r, c);
        if (d != null && !d.isBefore(t) && d.isBefore(end)) items.add((d, c, r));
      }
    }
    items.sort((a, b) {
      final byDay = a.$1.compareTo(b.$1);
      if (byDay != 0) return byDay;
      return a.$3.str(a.$2.timeField?.name ?? '').compareTo(b.$3.str(b.$2.timeField?.name ?? ''));
    });
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    DateTime? day;
    for (final (d, c, r) in _items) {
      if (d != day) {
        day = d;
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(dayLabel(d), style: TextStyle(color: d == today() ? accent : muted, fontSize: 15)),
          ),
        );
      }
      final time = c.timeField == null ? '' : r.str(c.timeField!.name);
      children.add(
        _Row(
          title: [if (time.isNotEmpty) time, r.str(c.titleField)].join('  '),
          sub: c.label,
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => RecordScreen(collection: c, rec: r),
              ),
            );
            await _load();
          },
        ),
      );
    }
    if (children.isEmpty) children.add(const Text('inget de närmaste 14 dagarna', style: TextStyle(color: muted)));
    return AltPage(
      back: 'Meny',
      title: 'Datum, 14 dagar',
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: children),
      ),
    );
  }
}

/// Poster från en fråga: titel, och datum och samling under.
class QueryResults extends StatelessWidget {
  const QueryResults({super.key, required this.items, required this.onChanged, this.showCollection = true});
  final List<(Collection, Rec)> items;
  final VoidCallback onChanged;
  final bool showCollection;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const Text('inga poster matchar', style: TextStyle(color: muted));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (c, r) in items)
          _Row(
            title: r.str(c.titleField),
            sub: [
              if (_date(r, c) case final d?) dayLabel(d),
              if (c.timeField != null) r.str(c.timeField!.name),
              if (showCollection) c.label,
            ].where((s) => s.isNotEmpty).join('  '),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RecordScreen(collection: c, rec: r),
                ),
              );
              onChanged();
            },
          ),
      ],
    );
  }
}

class QueryScreen extends StatefulWidget {
  const QueryScreen({super.key, required this.query, required this.collections, this.back = 'Meny'});
  final Query query;
  final List<Collection> collections;
  final String back;

  @override
  State<QueryScreen> createState() => _QueryScreenState();
}

class _QueryScreenState extends State<QueryScreen> {
  List<(Collection, Rec)>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await runQuery(widget.query, widget.collections);
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) {
    return AltPage(
      back: widget.back,
      title: widget.query.label,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            if (_items != null)
              QueryResults(
                items: _items!,
                onChanged: _load,
                showCollection: widget.query.sources(widget.collections).length > 1,
              ),
          ],
        ),
      ),
    );
  }
}

/// En rapport (`*.report.md`) räknad på telefonens poster. Länkar till poster går att trycka på.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, required this.report, required this.collections});
  final Report report;
  final List<Collection> collections;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  String? _md;
  final _taps = <TapGestureRecognizer>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    String md;
    try {
      // På telefonen finns alla poster i klartext, så även krypterade samlingar kan vara med.
      md = await renderReport(widget.report, await ReportData.load(widget.collections));
    } catch (e) {
      md = 'Rapporten gick inte att skriva: $e';
    }
    if (mounted) setState(() => _md = md);
  }

  Future<void> _open(String coll, String id) async {
    final c = widget.collections.where((c) => c.name == coll).firstOrNull;
    final r = c == null ? null : await readRecord(coll, id);
    if (r == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecordScreen(collection: c!, rec: r),
      ),
    );
    await _load();
  }

  /// Text med Markdown-länkar, där länkar till poster blir tryckbara.
  List<InlineSpan> _inline(String text, TextStyle style) {
    final s = text.replaceAll('**', '');
    final out = <InlineSpan>[];
    var at = 0;
    for (final m in RegExp(r'\[([^\]]+)\]\(([^)]+)\)').allMatches(s)) {
      if (m.start > at) out.add(TextSpan(text: s.substring(at, m.start), style: style));
      at = m.end;
      final target = RegExp(r'([a-zåäö][a-zåäö0-9_]*)/([^/]+)\.yaml$').firstMatch(Uri.decodeFull(m[2]!));
      if (target == null) {
        out.add(TextSpan(text: m[1], style: style));
        continue;
      }
      final tap = TapGestureRecognizer()..onTap = () => _open(target[1]!, target[2]!);
      _taps.add(tap);
      out.add(
        TextSpan(
          text: m[1],
          style: style.copyWith(color: accent),
          recognizer: tap,
        ),
      );
    }
    if (at < s.length) out.add(TextSpan(text: s.substring(at), style: style));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
    final lines = (_md ?? '').split('\n').where((l) => l != generatedMark).toList();
    // Rapportens egen första rubrik blir sidans titel.
    var title = widget.report.label;
    if (lines.isNotEmpty && lines.first.startsWith('# ')) title = lines.removeAt(0).substring(2);
    return AltPage(
      back: 'Meny',
      title: title,
      child: _md == null
          ? const SizedBox()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  for (final l in lines)
                    if (l.trim().isEmpty)
                      const SizedBox(height: 10)
                    else if (RegExp(r'^#{1,6} ').hasMatch(l))
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 2),
                        child: Text.rich(
                          TextSpan(
                            children: _inline(
                              l.replaceFirst(RegExp(r'^#+ '), ''),
                              TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: l.startsWith('## ') ? 20 : 18,
                                color: fg,
                              ),
                            ),
                          ),
                        ),
                      )
                    else if (RegExp(r'^\|[-|: ]+\|$').hasMatch(l.trim()))
                      const SizedBox()
                    else
                      Text.rich(
                        TextSpan(
                          children: _inline(
                            l.startsWith('- ')
                                ? '• ${l.substring(2)}'
                                : l.startsWith('|')
                                ? l
                                      .trim()
                                      .replaceAll(RegExp(r'^\||\|$'), '')
                                      .split(' | ')
                                      .map((x) => x.trim())
                                      .join('  ')
                                : l,
                            const TextStyle(fontSize: 16, color: fg, height: 1.45),
                          ),
                        ),
                      ),
                ],
              ),
            ),
    );
  }
}
