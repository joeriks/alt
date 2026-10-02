import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';

import 'engine.dart';

/// Skalets sida av receptkörningen: filer, körlogg, schema och notiser.
/// Används både av appen och av bakgrundskörningen (eget isolat).

const _bundled = ['recipes/hej.recipe'];
const scheduleId = 1;
const onceId = 2;

Future<Directory> _root() async => getApplicationSupportDirectory();

Future<Directory> recipesDir() async => Directory('${(await _root()).path}/recipes');
Future<Directory> storeDir() async => Directory('${(await _root()).path}/store');
Future<File> _logFile() async => File('${(await _root()).path}/runs.jsonl');
Future<File> _lockFile() async => File('${(await _root()).path}/run.lock');

/// Kopierar medföljande recept till appens mapp första gången.
Future<void> installBundledRecipes() async {
  final dir = await recipesDir();
  dir.createSync(recursive: true);
  for (final asset in _bundled) {
    final target = File('${dir.path}/${asset.split('/').last}');
    if (!target.existsSync()) target.writeAsStringSync(await rootBundle.loadString(asset));
  }
}

Future<List<Recipe>> loadRecipes() async {
  final dir = await recipesDir();
  if (!dir.existsSync()) return [];
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.recipe')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [for (final f in files) Recipe.parse(f.readAsStringSync())];
}

Future<List<Map<String, dynamic>>> readRuns({int limit = 50}) async {
  final f = await _logFile();
  if (!f.existsSync()) return [];
  final lines = f.readAsLinesSync().where((l) => l.isNotEmpty).toList();
  final start = lines.length > limit ? lines.length - limit : 0;
  return [for (final l in lines.sublist(start)) jsonDecode(l) as Map<String, dynamic>];
}

Future<void> clearRuns() async {
  final f = await _logFile();
  if (f.existsSync()) f.deleteSync();
}

/// Kör ett recept och tar hand om dess utdata. Körningar sker aldrig parallellt:
/// en låsfil som är yngre än två minuter gör att den nya körningen hoppas över.
Future<RunResult?> runAndDeliver(Recipe recipe, String trigger) async {
  final lock = await _lockFile();
  if (lock.existsSync() && DateTime.now().difference(lock.lastModifiedSync()) < const Duration(minutes: 2)) {
    return null;
  }
  lock.writeAsStringSync(recipe.name);
  try {
    final result = runRecipe(recipe, trigger: trigger, storeDir: await storeDir());
    (await _logFile()).writeAsStringSync('${jsonEncode(result.toJson())}\n', mode: FileMode.append, flush: true);
    for (final o in result.outputs) {
      if (o.kind == 'show') await showNotification(o.title, o.body);
    }
    if (!result.ok) await showNotification('Fel i ${recipe.label}', result.error!.split('\n').first);
    return result;
  } finally {
    if (lock.existsSync()) lock.deleteSync();
  }
}

// --- Notiser ---

final _notes = FlutterLocalNotificationsPlugin();
var _notesReady = false;

Future<void> _initNotes() async {
  if (_notesReady) return;
  await _notes.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
  );
  _notesReady = true;
}

Future<bool> requestNotificationPermission() async {
  await _initNotes();
  final android = _notes.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  final granted = await android?.requestNotificationsPermission() ?? true;
  await android?.requestExactAlarmsPermission();
  return granted;
}

Future<void> showNotification(String title, String body) async {
  await _initNotes();
  await _notes.show(
    id: DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000,
    title: title,
    body: body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails('recept', 'Recept', importance: Importance.high, priority: Priority.high),
    ),
  );
}

// --- Schema ---

/// Schemalägger varje recept som har en `every:`-trigger. Spiken har ett schema
/// för alla recept; det kortaste intervallet styr.
Future<Duration?> scheduleAll() async {
  Duration? shortest;
  for (final r in await loadRecipes()) {
    for (final t in r.triggers) {
      final d = parseEvery(t['every']?.toString());
      if (d != null && (shortest == null || d < shortest)) shortest = d;
    }
  }
  if (shortest == null) return null;
  await AndroidAlarmManager.periodic(
    shortest,
    scheduleId,
    backgroundCallback,
    exact: true,
    wakeup: true,
    allowWhileIdle: true,
    rescheduleOnReboot: true,
  );
  return shortest;
}

Future<void> scheduleOnceIn(Duration d) async {
  await AndroidAlarmManager.oneShot(
    d,
    onceId,
    backgroundCallback,
    exact: true,
    wakeup: true,
    allowWhileIdle: true,
    rescheduleOnReboot: true,
  );
}

Future<void> cancelSchedule() async {
  await AndroidAlarmManager.cancel(scheduleId);
  await AndroidAlarmManager.cancel(onceId);
}

/// Körs av Android i ett eget isolat, även när appen är stängd.
@pragma('vm:entry-point')
Future<void> backgroundCallback(int id) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final trigger = id == onceId ? 'once' : 'every';
  for (final r in await loadRecipes()) {
    final wants = r.triggers.any((t) => t.containsKey('every')) || id == onceId;
    if (wants) await runAndDeliver(r, trigger);
  }
}
