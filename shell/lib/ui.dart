import 'package:flutter/material.dart';

/// Färger och små byggstenar som alla skärmar delar. Recept styr aldrig utseendet.

const bg = Color(0xFF111210);
const fg = Color(0xFFE9E7E1);
const muted = Color(0xFFA3A19A);
const accent = Color(0xFFF0B44C);
const line = Color(0xFF24251F);
const red = Color(0xFFE5776B);

ThemeData altTheme() => ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: bg,
  fontFamily: 'monospace',
  colorScheme: const ColorScheme.dark(primary: accent, onPrimary: bg, surface: Color(0xFF1A1B18), onSurface: fg),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(fontSize: 18, height: 1.5, color: fg),
    bodyLarge: TextStyle(fontSize: 18, height: 1.5, color: fg),
  ),
  snackBarTheme: const SnackBarThemeData(
    backgroundColor: Color(0xFF2A2B26),
    contentTextStyle: TextStyle(fontFamily: 'monospace', fontSize: 16, color: fg),
    actionTextColor: accent,
    behavior: SnackBarBehavior.floating,
  ),
  inputDecorationTheme: const InputDecorationTheme(
    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: line)),
    focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: accent)),
    labelStyle: TextStyle(color: muted),
  ),
);

/// Skärmram: tillbakaknapp överst, innehåll, valfri rad längst ner.
class AltPage extends StatelessWidget {
  const AltPage({super.key, required this.back, required this.title, required this.child, this.bottom});

  final String back;
  final String title;
  final Widget child;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  onTap: () => Navigator.of(context).maybePop(),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: 1,
                      child: Text('‹ $back', style: const TextStyle(color: muted, fontSize: 18)),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
              ),
              Expanded(child: child),
              ?bottom,
            ],
          ),
        ),
      ),
    );
  }
}

/// Stor knapp längst ner, till exempel "+ Ny" eller "Spara".
class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label, {super.key, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SizedBox(
        height: 56,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: bg,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
            textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 18, fontWeight: FontWeight.w700),
          ),
          child: Text(label),
        ),
      ),
    );
  }
}

/// Visar en rad längst ner i 5 sekunder med "Ångra".
void showUndo(BuildContext context, String text, VoidCallback undo) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(label: 'Ångra', onPressed: undo),
      ),
    );
}

const _days = ['mån', 'tis', 'ons', 'tor', 'fre', 'lör', 'sön'];
const _months = ['jan', 'feb', 'mar', 'apr', 'maj', 'jun', 'jul', 'aug', 'sep', 'okt', 'nov', 'dec'];

DateTime today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// "fre 3 okt · i morgon"
String dayLabel(DateTime d) {
  final diff = d.difference(today()).inDays;
  final rel = switch (diff) {
    0 => ' · i dag',
    1 => ' · i morgon',
    -1 => ' · i går',
    _ => '',
  };
  final year = d.year != today().year ? ' ${d.year}' : '';
  return '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}$year$rel';
}

String isoDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
