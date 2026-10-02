// Tar skärmbilder av appens flöden. Körs bara med SCREENSHOTS=1:
//   SCREENSHOTS=1 flutter test test/screenshots_test.dart
// Bilderna hamnar i build/screens/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:alt/ai.dart';
import 'package:alt/ai_screen.dart';
import 'package:alt/dev.dart';
import 'package:alt/main.dart';
import 'package:alt/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePaths extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  _FakePaths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void _copy(Directory from, Directory to) {
  for (final f in from.listSync(recursive: true).whereType<File>()) {
    final t = File('${to.path}/${f.path.substring(from.path.length + 1)}');
    t.parent.createSync(recursive: true);
    f.copySync(t.path);
  }
}

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  final run = Platform.environment['SCREENSHOTS'] == '1';
  late Directory root;
  final out = Directory('build/screens');
  var n = 0;

  Future<void> shot(WidgetTester tester, String name) async {
    // Prompten blinkar för evigt, så pumpAndSettle går inte.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('shot')));
    await tester.runAsync(() async {
      final img = await boundary.toImage(pixelRatio: 1.5);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      out.createSync(recursive: true);
      File('${out.path}/${(++n).toString().padLeft(2, '0')}_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  setUpAll(() async {
    if (!run) return;
    final font = FontLoader('monospace')
      ..addFont(
        Future.value(
          ByteData.sublistView(File('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf').readAsBytesSync()),
        ),
      )
      ..addFont(
        Future.value(
          ByteData.sublistView(File('/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf').readAsBytesSync()),
        ),
      );
    await font.load();
    root = Directory.systemTemp.createTempSync('alt');
    _copy(Directory('test/fixture'), Directory('${root.path}/workspace'));
    // Svenska etiketter oavsett testmaskinens språk.
    final code = Platform.localeName.split(RegExp('[_.-]')).first.toLowerCase();
    File('${root.path}/workspace/lang/sv.yaml').copySync('${root.path}/workspace/lang/$code.yaml');
    final t = DateTime.now();
    void rec(String coll, String id, String body) {
      File('${root.path}/data/$coll/$id.yaml')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(body);
    }

    rec(
      'private_calendar',
      'tandläkare',
      'date: "${_iso(t.add(const Duration(days: 4)))}"\ntime: "14:30"\ntitle: "Tandläkare"\n',
    );
    rec(
      'private_calendar',
      'mammas_födelsedag',
      'date: "${_iso(t.add(const Duration(days: 8)))}"\ntitle: "Mammas födelsedag"\nnote: "Köp blommor"\n',
    );
    rec(
      'work_calendar',
      'sprintdemo',
      'date: "${_iso(t.add(const Duration(days: 1)))}"\ntime: "10:00"\ntitle: "Sprintdemo"\nproject: "alve"\n',
    );
    rec('private_calendar', 'gammalt', 'date: "${_iso(t.subtract(const Duration(days: 20)))}"\ntitle: "Besiktning"\n');
    PathProviderPlatform.instance = _FakePaths(root.path);
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('flöden', (tester) async {
    tester.view.physicalSize = const Size(412 * 1.5, 892 * 1.5);
    tester.view.devicePixelRatio = 1.5;
    await tester.pumpWidget(const RepaintBoundary(key: Key('shot'), child: AltApp()));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
    await shot(tester, 'start');

    await tester.tap(find.textContaining('Minnesbank'));
    await shot(tester, 'minnesbank');

    await tester.tap(find.text('Privat kalender'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await shot(tester, 'lista');

    await tester.tap(find.text('Mammas födelsedag'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await shot(tester, 'post');

    await tester.tap(find.text('redigera'));
    await shot(tester, 'redigera');
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('+ Ny'));
    await shot(tester, 'ny_tom');
    await tester.tap(find.text('Spara'));
    await shot(tester, 'ny_fel');
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.enterText(find.byType(TextField), 'dag');
    await shot(tester, 'sok');
    await tester.tap(find.text('Datum / 14 dagar').last);
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await shot(tester, 'tidslinje');
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.enterText(find.byType(TextField), 'filer');
    await shot(tester, 'sok_filer');
    await tester.tap(find.text('Utveckla / Filer'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await shot(tester, 'filer');
    await tester.tap(find.text('private_calendar.collection.yaml'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await shot(tester, 'kod');
    await tester.tap(find.text('Redigera'));
    await shot(tester, 'editor');

    for (var i = 0; i < 3; i++) {
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.enterText(find.byType(TextField), 'böcker jag har läst');
    await shot(tester, 'sok_ingen_traff');
    await tester.tap(find.textContaining('Fråga AI'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
    await shot(tester, 'ai_fraga');

    final sv = File('${root.path}/workspace/lang/sv.yaml').readAsStringSync();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('shot'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: altTheme(),
          home: AiScreen(
            proposal: AiProposal(
              'La till samlingen Books i Memory bank med titel, författare, betyg och datum, '
              'och svenska etiketter.',
              [
                AiFile(
                  'apps/memory_bank/books.collection.yaml',
                  'label: Books\ntitle: title\nfields:\n  title: { text, required, label: Title }\n'
                      '  author: { text, label: Author }\n  rating: { number, label: Rating }\n'
                      '  finished: { date, label: Finished }\n',
                ),
                AiFile(
                  'lang/sv.yaml',
                  '$sv  books:\n    label: Böcker\n    fields:\n      title: Titel\n'
                      '      author: Författare\n      rating: Betyg\n      finished: Utläst\n',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
    await shot(tester, 'ai_forslag');
    await tester.tap(find.text('Spara utkast'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
    await shot(tester, 'ai_sparat');

    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('shot'),
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: altTheme(), home: const DevFilesScreen()),
      ),
    );
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    await shot(tester, 'filer_utkast');
    await tester.tap(find.textContaining('till GitHub'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await shot(tester, 'spara_fraga');
    await tester.tap(find.text('Avbryt'));

    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('shot'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: altTheme(),
          home: AiScreen(
            proposal: AiProposal(
              'De här posterna i Privat kalender ligger framför dig de närmaste 30 dagarna.',
              [
                AiFile(
                  'apps/memory_bank/upcoming.query.yaml',
                  'label: Upcoming\nfrom: private_calendar\nwhere:\n  date: { from: today, to: today+30d }\nsort: date\n',
                ),
              ],
              ore: 0.8,
              run: 'apps/memory_bank/upcoming.query.yaml',
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 6));
    await shot(tester, 'ai_svar_lista');
  }, skip: !run);
}
