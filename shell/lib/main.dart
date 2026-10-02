import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/material.dart';

import 'dev.dart';
import 'engine.dart';
import 'host.dart';
import 'screens.dart';
import 'ui.dart';
import 'workspace.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AndroidAlarmManager.initialize();
  await installBundledRecipes();
  runApp(const AltApp());
}

class AltApp extends StatelessWidget {
  const AltApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'alt', debugShowCheckedModeBanner: false, theme: altTheme(), home: const Home());
  }
}

class _Cmd {
  _Cmd(this.label, this.action);
  final String label;
  final Future<void> Function() action;

  List<String> get segments => label.split('/').map((s) => s.trim()).toList();
}

/// Menyn på en nivå i trädet. Etiketter som "Minnesbank / Privat kalender" delas
/// vid `/`. Returnerar (namn, index) för kommandon och (namn, null) för undermenyer.
List<(String, int?)> menuLevel(List<String> labels, List<String> path) {
  final out = <(String, int?)>[];
  final folders = <String>{};
  for (var i = 0; i < labels.length; i++) {
    final segs = labels[i].split('/').map((s) => s.trim()).toList();
    if (segs.length <= path.length) continue;
    var under = true;
    for (var k = 0; k < path.length; k++) {
      if (segs[k] != path[k]) under = false;
    }
    if (!under) continue;
    final next = segs[path.length];
    if (segs.length == path.length + 1) {
      out.add((next, i));
    } else if (folders.add(next)) {
      out.add((next, null));
    }
  }
  return out;
}

/// En rad i menyn: antingen ett kommando eller en undermeny (cmd == null).
class _Entry {
  _Entry(this.label, this.cmd);
  final String label;
  final _Cmd? cmd;
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final _q = TextEditingController();

  /// Var i menyträdet man står, till exempel ['Minnesbank'].
  final List<String> _path = [];
  List<Recipe> _recipes = [];
  Workspace _ws = Workspace([], [], []);
  List<Map<String, dynamic>> _runs = [];
  String? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _q.addListener(() => setState(() {}));
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _q.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _reload() async {
    final ws = await Workspace.load();
    final recipes = await loadRecipes();
    final runs = await readRuns();
    if (!mounted) return;
    setState(() {
      _ws = ws;
      _recipes = recipes;
      _runs = runs;
    });
  }

  void _say(String s) => setState(() => _status = s);

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _askToken() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1B18),
        title: const Text('GitHub-nyckel', style: TextStyle(fontSize: 20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Läsrätt till ${defaultRepo.split('/').last}. Sparas krypterad på telefonen.',
              style: const TextStyle(color: muted, fontSize: 15),
            ),
            TextField(controller: ctl, obscureText: true, autofocus: true, cursorColor: accent),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Avbryt')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Spara')),
        ],
      ),
    );
    if (ok == true && ctl.text.trim().isNotEmpty) {
      await setGithubToken(ctl.text);
      _say('nyckeln sparad, kör Synka / Hämta recept');
    }
    ctl.dispose();
  }

  List<_Cmd> get _commands => [
    if (_ws.collections.any((c) => c.role == 'timeline'))
      _Cmd(
        'Datum / 14 dagar',
        () => _push(
          TimelineScreen(
            collections: [
              for (final c in _ws.collections)
                if (c.role == 'timeline') c,
            ],
          ),
        ),
      ),
    for (final c in _ws.collections) _Cmd('${c.appLabel} / ${c.label}', () => _push(CollectionScreen(collection: c))),
    for (final r in _recipes)
      for (final t in r.triggers)
        if (t['menu'] != null)
          _Cmd(t['menu'].toString(), () async {
            final res = await runAndDeliver(r, 'menu');
            _say(
              res == null
                  ? 'en körning pågår redan'
                  : res.ok
                  ? 'klar på ${res.ms} ms'
                  : 'fel: ${res.error}',
            );
          }),
    _Cmd('Synka / Hämta recept', () async {
      _say('hämtar…');
      try {
        final n = await syncWorkspace();
        final ws = await Workspace.load();
        _say('hämtade $n filer${ws.problems.isEmpty ? '' : ', fel i ${ws.problems.join('; ')}'}');
      } catch (e) {
        _say('kunde inte hämta: $e');
      }
    }),
    _Cmd('Inställningar / GitHub-nyckel', _askToken),
    _Cmd('Utveckla / Filer', () => _push(const DevFilesScreen())),
    _Cmd('Schema / Starta', () async {
      await requestNotificationPermission();
      final d = await scheduleAll();
      _say(d == null ? 'inget recept har every:' : 'körs var ${d.inMinutes} min, även när appen är stängd');
    }),
    _Cmd('Schema / Prova om 1 min', () async {
      await requestNotificationPermission();
      await scheduleOnceIn(const Duration(minutes: 1));
      _say('stäng appen och vänta på notisen');
    }),
    _Cmd('Schema / Stoppa', () async {
      await cancelSchedule();
      _say('schemat stoppat');
    }),
    _Cmd('Logg / Rensa', () async {
      await clearRuns();
      _say('loggen rensad');
    }),
  ];

  Future<void> _runCmd(_Cmd c) async {
    _q.clear();
    FocusScope.of(context).unfocus();
    await c.action();
    await _reload();
  }

  List<_Entry> _level(List<_Cmd> cmds) => [
    for (final (label, index) in menuLevel([for (final c in cmds) c.label], _path))
      _Entry(label, index == null ? null : cmds[index]),
  ];

  void _up() => setState(() => _path.removeLast());

  @override
  Widget build(BuildContext context) {
    final q = _q.text.toLowerCase();
    final cmds = _commands;
    // En sökning letar i hela trädet och visar hela vägen; annars visas nivån man står på.
    final entries = q.isEmpty
        ? _level(cmds)
        : [
            for (final c in cmds)
              if (c.label.toLowerCase().contains(q)) _Entry(c.segments.join(' / '), c),
          ];
    final hits = [
      for (final e in entries)
        if (e.cmd != null) e.cmd!,
    ];

    return PopScope(
      // Tillbakagesten tömmer först sökningen, sedan går den upp en menynivå.
      canPop: q.isEmpty && _path.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (q.isNotEmpty) {
          _q.clear();
        } else {
          _up();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _reload,
                    child: _RunList(runs: _runs),
                  ),
                ),
                if (_status != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(_status!, style: const TextStyle(color: muted, fontSize: 15)),
                  ),
                if (_path.isNotEmpty && q.isEmpty)
                  InkWell(
                    onTap: _up,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('‹ ${_path.join(' / ')}', style: const TextStyle(color: muted)),
                      ),
                    ),
                  ),
                for (final e in entries)
                  InkWell(
                    onTap: () => e.cmd == null ? setState(() => _path.add(e.label)) : _runCmd(e.cmd!),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text.rich(
                          TextSpan(
                            text: e.label,
                            style: TextStyle(color: q.isNotEmpty && e.cmd == hits.firstOrNull ? accent : fg),
                            children: [
                              if (e.cmd == null)
                                const TextSpan(
                                  text: ' +',
                                  style: TextStyle(color: muted),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (entries.isEmpty) const Text('inget som matchar', style: TextStyle(color: muted)),
                const SizedBox(height: 12),
                Container(
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: line)),
                  ),
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Row(
                    children: [
                      const Text('> ', style: TextStyle(color: accent, fontSize: 20)),
                      Expanded(
                        child: TextField(
                          controller: _q,
                          cursorColor: accent,
                          cursorWidth: 10,
                          style: const TextStyle(fontSize: 20, color: fg),
                          decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                          onSubmitted: (_) {
                            if (hits.isNotEmpty) _runCmd(hits.first);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Körloggen: senaste körningen längst ner, med tid sedan föregående körning
/// så att man ser hur mycket Android förskjuter schemat.
class _RunList extends StatelessWidget {
  const _RunList({required this.runs});
  final List<Map<String, dynamic>> runs;

  String _hms(DateTime t) => [t.hour, t.minute, t.second].map((n) => n.toString().padLeft(2, '0')).join(':');

  @override
  Widget build(BuildContext context) {
    if (runs.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 40),
          Text('inga körningar än', style: TextStyle(color: muted)),
        ],
      );
    }
    return ListView.builder(
      reverse: true,
      itemCount: runs.length,
      itemBuilder: (context, i) {
        final idx = runs.length - 1 - i;
        final r = runs[idx];
        final t = DateTime.parse(r['started']);
        String gap = '';
        if (idx > 0) {
          final prev = DateTime.parse(runs[idx - 1]['started']);
          final d = t.difference(prev);
          gap = '  +${d.inMinutes}m${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
        }
        final ok = r['ok'] == true;
        final outs = (r['outputs'] as List? ?? const []).map((o) => o['body']).join(' · ');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${_hms(t)}  ${r['trigger']}$gap', style: const TextStyle(color: muted, fontSize: 15)),
              Text(
                ok ? outs : (r['error'] ?? 'fel').toString(),
                style: TextStyle(color: ok ? fg : red, fontSize: ok ? 18 : 15),
              ),
              Text('${r['recipe']} · ${r['ms']} ms', style: const TextStyle(color: muted, fontSize: 13)),
            ],
          ),
        );
      },
    );
  }
}
