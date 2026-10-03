import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/material.dart';

import 'ai.dart';
import 'ai_screen.dart';
import 'dev.dart';
import 'engine.dart';
import 'host.dart';
import 'records.dart';
import 'screens.dart';
import 'sync.dart';
import 'sync_screen.dart';
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
  final under = <String, List<int>>{};
  for (var i = 0; i < labels.length; i++) {
    final segs = labels[i].split('/').map((s) => s.trim()).toList();
    if (segs.length <= path.length) continue;
    var inside = true;
    for (var k = 0; k < path.length; k++) {
      if (segs[k] != path[k]) inside = false;
    }
    if (!inside) continue;
    final next = segs[path.length];
    if (segs.length == path.length + 1) {
      out.add((next, i));
    } else {
      if (!under.containsKey(next)) out.add((next, null));
      under.putIfAbsent(next, () => []).add(i);
    }
  }
  // En undermeny med ett enda val visas som det valet direkt, till exempel "Datum / 14 dagar".
  return [
    for (final (name, index) in out)
      if (index == null && under[name]!.length == 1)
        (labels[under[name]!.first].split('/').map((s) => s.trim()).skip(path.length).join(' / '), under[name]!.first)
      else
        (name, index),
  ];
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
  String? _status;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _q.addListener(() => setState(() {}));
    _focus.addListener(() => setState(() {}));
    // En ändrad post skickas till datarepot några sekunder senare, så att flera ändringar blir en commit.
    onRecordsChanged = () {
      _syncTimer?.cancel();
      _syncTimer = Timer(const Duration(seconds: 5), () => _sync());
    };
    _reload().then((_) => _sync());
  }

  Timer? _syncTimer;

  /// Synkar posterna med datarepot. I bakgrunden sägs bara det som behöver göras något åt.
  Future<void> _sync({bool quiet = true}) async {
    if (((await githubToken()) ?? '').isEmpty) {
      if (!quiet) _say('lägg in en GitHub-nyckel under System / GitHub-nyckel först');
      return;
    }
    if (!quiet) _say('synkar…');
    try {
      final r = await syncData();
      if (!mounted) return;
      if (r.clashes.isNotEmpty) {
        _say(r.summary);
        final done = await Navigator.of(context).push<SyncResult>(
          MaterialPageRoute(
            builder: (_) => ClashScreen(clashes: r.clashes, collections: _ws.collections),
          ),
        );
        if (done != null) _say(done.summary);
      } else if (!quiet || r.received > 0 || r.locked.isNotEmpty) {
        _say(r.summary);
      }
    } catch (e) {
      if (mounted) _say('synken misslyckades: $e');
    }
  }

  Future<void> _askPassphrase() async {
    final a = TextEditingController(), b = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1B18),
        title: const Text('Lösenfras', style: TextStyle(fontSize: 20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Krypterade samlingar låses med den här frasen innan de skickas till GitHub. '
              'Använd samma fras på en ny telefon. Glömmer du den går posterna på GitHub inte att läsa.',
              style: TextStyle(color: muted, fontSize: 15),
            ),
            TextField(
              controller: a,
              obscureText: true,
              autofocus: true,
              cursorColor: accent,
              decoration: const InputDecoration(hintText: 'lösenfras'),
            ),
            TextField(
              controller: b,
              obscureText: true,
              cursorColor: accent,
              decoration: const InputDecoration(hintText: 'samma igen'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Avbryt')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Spara')),
        ],
      ),
    );
    final phrase = a.text;
    final same = a.text == b.text;
    a.dispose();
    b.dispose();
    if (ok != true || phrase.isEmpty) return;
    if (!same) {
      _say('fraserna var inte lika, försök igen');
      return;
    }
    if (phrase.length < 12) {
      _say('lösenfrasen behöver minst 12 tecken, gärna några ord');
      return;
    }
    _say('räknar fram nyckeln…');
    try {
      await setPassphrase(phrase);
      _say('lösenfrasen sparad');
      await _sync(quiet: false);
    } catch (e) {
      _say('$e');
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    onRecordsChanged = null;
    WidgetsBinding.instance.removeObserver(this);
    _q.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _reload() async {
    final ws = await Workspace.load();
    final recipes = await loadRecipes();
    if (!mounted) return;
    setState(() {
      _ws = ws;
      _recipes = recipes;
    });
  }

  void _say(String s) => setState(() => _status = s);

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _askToken() => _askSecret(
    'GitHub-nyckel',
    'Läs- och skrivrätt (Contents) till ${defaultRepo.split('/').last} och ${defaultDataRepo.split('/').last}. '
        'Sparas krypterad på telefonen.',
    setGithubToken,
    'nyckeln sparad, kör System / Hämta recept',
  );

  Future<void> _askClaudeKey() => _askSecret(
    'Claude-nyckel',
    'En API-nyckel från console.anthropic.com. Sparas krypterad på telefonen.',
    setClaudeKey,
    'nyckeln sparad, välj modell under System / AI / Välj modell',
  );

  Future<void> _askOpenAiKey() => _askSecret(
    'OpenAI-nyckel',
    'En API-nyckel från platform.openai.com. Sparas krypterad på telefonen.',
    setOpenAiKey,
    'nyckeln sparad, välj modell under System / AI / Välj modell',
  );

  Future<void> _chooseModel() async {
    final current = await aiModel();
    final hasKey = {
      AiService.claude: ((await claudeKey()) ?? '').isNotEmpty,
      AiService.openai: ((await openAiKey()) ?? '').isNotEmpty,
    };
    if (!mounted) return;
    final picked = await showModalBottomSheet<AiModel>(
      context: context,
      backgroundColor: const Color(0xFF1A1B18),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            const Text('Välj AI-modell', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                'Billigast först. Dyrare modeller förstår svårare frågor bättre.',
                style: TextStyle(color: muted, fontSize: 15),
              ),
            ),
            for (final m in aiModels)
              InkWell(
                onTap: () => Navigator.pop(ctx, m),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(m.name, style: TextStyle(color: m.id == current.id ? accent : fg)),
                        Text(
                          [
                            'ca ${m.typicalOre.round()} öre per fråga',
                            if (!hasKey[m.service]!) 'ingen ${m.service.label}-nyckel',
                            if (m.id == current.id) 'vald',
                          ].join(' · '),
                          style: const TextStyle(color: muted, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await setAiModel(picked);
    _say(
      hasKey[picked.service]!
          ? 'Fråga AI använder nu ${picked.name}'
          : 'vald: ${picked.name}, lägg in en ${picked.service.label}-nyckel under System / AI',
    );
  }

  Future<void> _askSecret(String title, String help, Future<void> Function(String) save, String done) async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1B18),
        title: Text(title, style: const TextStyle(fontSize: 20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(help, style: const TextStyle(color: muted, fontSize: 15)),
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
      await save(ctl.text);
      _say(done);
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
    for (final q in _ws.queries)
      _Cmd('${q.appLabel} / ${q.label}', () => _push(QueryScreen(query: q, collections: _ws.collections))),
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
    _Cmd('System / Hämta recept', () async {
      _say('hämtar…');
      try {
        final n = await syncWorkspace();
        final ws = await Workspace.load();
        _say('hämtade $n filer${ws.problems.isEmpty ? '' : ', fel i ${ws.problems.join('; ')}'}');
      } catch (e) {
        _say('kunde inte hämta: $e');
      }
    }),
    _Cmd('System / GitHub-nyckel', _askToken),
    _Cmd('System / Data / Synka nu', () => _sync(quiet: false)),
    _Cmd('System / Data / Lösenfras', _askPassphrase),
    _Cmd('System / AI / Claude-nyckel', _askClaudeKey),
    _Cmd('System / AI / OpenAI-nyckel', _askOpenAiKey),
    _Cmd('System / AI / Välj modell', _chooseModel),
    _Cmd('Utveckla / Filer', () => _push(const DevFilesScreen())),
    _Cmd('Utveckla / Fråga AI', () => _push(const AiScreen())),
    _Cmd('Utveckla / Ny fråga', () => newQuery(context)),
    _Cmd('System / Schema / Starta', () async {
      await requestNotificationPermission();
      final d = await scheduleAll();
      _say(d == null ? 'inget recept har every:' : 'körs var ${d.inMinutes} min, även när appen är stängd');
    }),
    _Cmd('System / Schema / Prova om 1 min', () async {
      await requestNotificationPermission();
      await scheduleOnceIn(const Duration(minutes: 1));
      _say('stäng appen och vänta på notisen');
    }),
    _Cmd('System / Schema / Stoppa', () async {
      await cancelSchedule();
      _say('schemat stoppat');
    }),
    _Cmd('System / Körlogg', () => _push(const _LogScreen())),
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

  /// Det man skrev i prompten skickas direkt till AI:n.
  void _askAi() {
    final ask = _q.text;
    _q.clear();
    FocusScope.of(context).unfocus();
    _push(AiScreen(ask: ask, send: true)).then((_) => _reload());
  }

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
                const Spacer(),
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
                // Ingen träff: erbjud att låta AI:n bygga det man skrev.
                if (entries.isEmpty)
                  InkWell(
                    onTap: _askAi,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text.rich(
                          TextSpan(
                            text: 'Fråga AI: ',
                            style: const TextStyle(color: accent),
                            children: [
                              TextSpan(
                                text: _q.text,
                                style: const TextStyle(color: fg),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
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
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            // Blinkande markör när prompten väntar, som i en terminal.
                            if (q.isEmpty && !_focus.hasFocus) const IgnorePointer(child: _BlinkingBlock()),
                            TextField(
                              controller: _q,
                              focusNode: _focus,
                              cursorColor: accent,
                              cursorWidth: 10,
                              style: const TextStyle(fontSize: 20, color: fg),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                isDense: true,
                              ),
                              onSubmitted: (_) {
                                if (hits.isNotEmpty) {
                                  _runCmd(hits.first);
                                } else if (q.trim().isNotEmpty) {
                                  _askAi();
                                }
                              },
                            ),
                          ],
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

class _BlinkingBlock extends StatefulWidget {
  const _BlinkingBlock();

  @override
  State<_BlinkingBlock> createState() => _BlinkingBlockState();
}

class _BlinkingBlockState extends State<_BlinkingBlock> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1060))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => Opacity(
      opacity: _c.value < 0.5 ? 1 : 0,
      child: const Text('█', style: TextStyle(color: accent, fontSize: 20)),
    ),
  );
}

class _LogScreen extends StatefulWidget {
  const _LogScreen();

  @override
  State<_LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<_LogScreen> {
  List<Map<String, dynamic>> _runs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final runs = await readRuns();
    if (mounted) setState(() => _runs = runs);
  }

  @override
  Widget build(BuildContext context) {
    return AltPage(
      back: 'System',
      title: 'Körlogg',
      bottom: _runs.isEmpty
          ? null
          : Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () async {
                  await clearRuns();
                  await _load();
                },
                child: const Text('rensa', style: TextStyle(color: muted)),
              ),
            ),
      child: RefreshIndicator(
        onRefresh: _load,
        child: _RunList(runs: _runs),
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
