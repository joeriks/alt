import 'package:flutter/material.dart';

import 'sync.dart';
import 'ui.dart';
import 'workspace.dart';

/// Poster som ändrats både på telefonen och på GitHub sedan förra synken. Du väljer vilken version som gäller.
class ClashScreen extends StatefulWidget {
  const ClashScreen({super.key, required this.clashes, required this.collections});
  final List<SyncClash> clashes;
  final List<Collection> collections;

  @override
  State<ClashScreen> createState() => _ClashScreenState();
}

class _ClashScreenState extends State<ClashScreen> {
  /// samling/id → true för telefonens version, false för GitHubs.
  final _choice = <String, bool>{};
  String? _error;
  bool _busy = false;

  Future<void> _apply() async {
    setState(() => _busy = true);
    try {
      final r = await syncData(resolved: _choice);
      if (!mounted) return;
      Navigator.of(context).pop(r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  String _show(Collection? c, Map<String, dynamic>? v) {
    if (v == null) return 'borttagen';
    if (c == null) return v.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    return [
      for (final f in c.fields)
        if (v[f.name] != null && v[f.name] != '') '${f.label}: ${v[f.name]}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.clashes.every((k) => _choice.containsKey('${k.collection}/${k.id}'));
    return AltPage(
      back: 'Meny',
      title: 'Krockar',
      child: ListView(
        children: [
          const Text(
            'De här posterna har ändrats både på telefonen och på GitHub. Välj vilken version som ska gälla. '
            'Den andra försvinner inte, den finns kvar i historiken.',
            style: TextStyle(color: muted, fontSize: 15),
          ),
          for (final k in widget.clashes) ...[
            const SizedBox(height: 20),
            Text(
              '${k.mine?['title'] ?? k.theirs?['title'] ?? k.id}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final (label, mine, values) in [('Den här telefonen', true, k.mine), ('GitHub', false, k.theirs)])
              InkWell(
                onTap: () => setState(() => _choice['${k.collection}/${k.id}'] = mine),
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _choice['${k.collection}/${k.id}'] == mine ? accent : line,
                      width: _choice['${k.collection}/${k.id}'] == mine ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: const TextStyle(color: muted, fontSize: 14)),
                      Text(
                        _show(widget.collections.where((c) => c.name == k.collection).firstOrNull, values),
                        style: const TextStyle(fontSize: 15),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          if (_error != null) ...[const SizedBox(height: 16), Text(_error!, style: const TextStyle(color: red))],
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: all && !_busy ? _apply : null,
              child: Text(_busy ? 'synkar…' : 'Använd valen', style: TextStyle(color: all && !_busy ? accent : muted)),
            ),
          ),
        ],
      ),
    );
  }
}
