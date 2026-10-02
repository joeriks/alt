# shell

Flutter-skalet. Det byggs en gång till en APK och kör sedan recept utan nytt bygge.

Just nu är det en spike som svarar på en fråga: kan ett JavaScript-recept köras i QuickJS
på en schemalagd tid, även när appen är stängd?

## Prova

1. Installera `alt.apk` från releasen [senaste](https://github.com/joeriks/alt/releases/tag/senaste).
2. Skriv eller tryck `Spike / Hej`: receptet körs direkt och visar en notis.
3. `Schema / Prova om 1 min`, stäng appen och vänta på notisen.
4. `Schema / Starta` kör receptet var 15:e minut. Loggen visar tiden mellan körningarna,
   så att man ser hur mycket Android förskjuter schemat.

## Delar

- `recipes/hej.recipe` är testreceptet: YAML-huvud och JavaScript med `function run(ctx)`.
- `lib/engine.dart` tolkar recept och kör dem i en ny QuickJS-runtime (flutter_js).
- `lib/host.dart` sköter filer, körlogg, schema (android_alarm_manager_plus) och notiser.
- `lib/main.dart` är startsidan med kommandoprompten längst ner.

Signeringsnyckeln `android/app/spike.keystore` är publik med avsikt så att varje bygge kan
installeras över det förra. Den byts mot en hemlig nyckel innan appen får riktig data.
