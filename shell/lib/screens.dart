import 'package:flutter/material.dart';

import 'records.dart';
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
              if (sub != null && sub!.isNotEmpty) Text(sub!, style: const TextStyle(color: muted, fontSize: 15)),
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
    if (mounted) setState(() => _recs = recs);
  }

  String _sub(Rec r) {
    final d = _date(r, c);
    return [
      if (d != null) dayLabel(d),
      if (c.timeField != null) r.str(c.timeField!.name),
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
  const RecordScreen({super.key, required this.collection, required this.rec});
  final Collection collection;
  final Rec rec;

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  late Rec _rec = widget.rec;
  int _versions = 0;

  Collection get c => widget.collection;

  @override
  void initState() {
    super.initState();
    historyCount(_rec).then((n) => mounted ? setState(() => _versions = n) : null);
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
    _versions = await historyCount(saved);
    if (!mounted) return;
    setState(() {});
    showUndo(context, 'Ändringen sparad', () async {
      await restoreRecord(before);
      if (mounted) setState(() => _rec = before);
    });
  }

  Future<void> _delete() async {
    final r = _rec;
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

  @override
  Widget build(BuildContext context) {
    return AltPage(
      back: c.label,
      title: _rec.str(c.titleField),
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
                    Text(
                      f.type == 'date' && DateTime.tryParse(_rec.str(f.name)) != null
                          ? dayLabel(DateTime.parse(_rec.str(f.name)))
                          : _rec.str(f.name),
                    ),
                  ],
                ),
              ),
          if (_versions > 0)
            Text(
              '$_versions tidigare ${_versions == 1 ? 'version' : 'versioner'}',
              style: const TextStyle(color: muted, fontSize: 15),
            ),
          const SizedBox(height: 24),
          Row(
            children: [
              TextButton(
                onPressed: _edit,
                child: const Text('redigera', style: TextStyle(color: accent)),
              ),
              const SizedBox(width: 16),
              TextButton(
                onPressed: _delete,
                child: const Text('ta bort', style: TextStyle(color: muted)),
              ),
            ],
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
  late final Map<String, dynamic> _v = {...?widget.initial, ...?widget.rec?.values};
  final Map<String, TextEditingController> _text = {};
  String? _error;

  Collection get c => widget.collection;

  @override
  void initState() {
    super.initState();
    for (final f in c.fields) {
      if (f.type == 'text' || f.type == 'longtext' || f.type == 'number' || f.type == 'link') {
        _text[f.name] = TextEditingController(text: _v[f.name]?.toString() ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (final t in _text.values) {
      t.dispose();
    }
    super.dispose();
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
      setState(() => _error = 'Fyll i ${missing.map((f) => f.label).join(' och ')} först.');
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
              'bool' => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(f.label),
                value: _v[f.name] == true,
                onChanged: (x) => setState(() => _v[f.name] = x == true),
              ),
              _ => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: TextField(
                  controller: _text[f.name],
                  autofocus: f.name == c.titleField && widget.rec == null,
                  minLines: f.type == 'longtext' ? 3 : 1,
                  maxLines: f.type == 'longtext' ? 8 : 1,
                  keyboardType: f.type == 'number' ? TextInputType.number : TextInputType.text,
                  textCapitalization: TextCapitalization.sentences,
                  cursorColor: accent,
                  decoration: InputDecoration(labelText: f.label + (f.required ? '' : '  (valfritt)')),
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
