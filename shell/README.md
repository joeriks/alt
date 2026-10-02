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

## Samlingar

Skalet hämtar appar, samlingar och recept från receptrepot (standard `joeriks/alt-my-recepies`)
med `Synka / Hämta recept`. Det kräver en GitHub-nyckel med läsrätt till repot, som läggs in
under `Inställningar / GitHub-nyckel` och sparas krypterad på telefonen.

Varje `*.collection.yaml` blir ett menyval med lista, post, formulär, borttagning och Ångra.
Samlingar med `role: timeline` syns också i `Datum / 14 dagar`. En typ i `types/<namn>.type.yaml`
ger flera samlingar samma fält (`type: <namn>`); en samling får lägga till fält men inte ändra typens.
Namn och etiketter skrivs på engelska; `lang/<språk>.yaml` i receptrepot ersätter etiketterna
när telefonen har det språket. Poster sparas som en fil per
post i appens mapp; synk mot datarepot kommer i nästa steg.

## Utveckla

`Utveckla / Filer` listar alla hämtade filer. En fil kan visas med radnummer, redigeras och
sparas som utkast på telefonen, och provas med `Prova`:
- ett recept körs mot en egen utkastlagring och visar sin utdata i stället för att skicka notiser
- en samling öppnar sitt formulär som förhandsvisning
- typer, språkfiler och app.yaml laddas om tillsammans med alla samlingar och visar eventuella fel

Utkast påverkar inget annat förrän de sparas till GitHub, vilket är nästa steg.

## Delar

- `recipes/hej.recipe` är testreceptet: YAML-huvud och JavaScript med `function run(ctx)`.
- `lib/engine.dart` tolkar recept och kör dem i en ny QuickJS-runtime (flutter_js).
- `lib/host.dart` sköter filer, körlogg, schema (android_alarm_manager_plus) och notiser.
- `lib/workspace.dart` hämtar och tolkar appar, samlingar och recept.
- `lib/records.dart` sparar poster, historik och papperskorg.
- `lib/screens.dart` är lista, post, formulär och datumvy.
- `lib/dev.dart` är Utveckla: fillista, kodvy, redigering och Prova.
- `lib/main.dart` är startsidan med kommandoprompten längst ner.

Signeringsnyckeln `android/app/spike.keystore` är publik med avsikt så att varje bygge kan
installeras över det förra. Den byts mot en hemlig nyckel innan appen får riktig data.
