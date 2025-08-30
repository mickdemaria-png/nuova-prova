# Script Learner (Flutter)

App per studiare copioni teatrali su Android:
- Import PDF/DOCX/TXT
- Parsing con regole configurabili (o regex personalizzata)
- Scelta personaggio; studio per Atto/Scena/Tutto
- TTS (lettura), pausa e prompt lento
- STT (verifica), punteggio e lista errori

## Build in cloud (GitHub Actions)
1. Carica questo progetto in un repo.
2. Vai su **Actions** → esegui il workflow "Build Flutter APK (Cloud)".
3. Scarica l'APK da **Artifacts → app-release**.

## Esecuzione locale
```
flutter pub get
flutter run
```
