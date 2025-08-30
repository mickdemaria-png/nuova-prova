//
// Script Learner – MVP completo in Flutter
//
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf_text/pdf_text.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:xml/xml.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScriptLearnerApp());
}

class ScriptLearnerApp extends StatelessWidget {
  const ScriptLearnerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ScriptModel()),
        ChangeNotifierProvider(create: (_) => StudyModel()),
      ],
      child: MaterialApp(
        title: 'Script Learner',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo), useMaterial3: true),
        home: const HomeScreen(),
      ),
    );
  }
}

// ========================= MODELS =========================
class ScriptModel extends ChangeNotifier {
  String? rawText;
  List<ScriptBlock> blocks = [];
  Set<String> characters = {};
  List<String> acts = [];
  List<String> scenes = [];
  ParsingConfig config = ParsingConfig.defaults();

  bool get hasScript => (rawText ?? '').trim().isNotEmpty;

  Future<void> loadFromFile() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf','docx','txt','md']);
    if (res == null || res.files.single.path == null) return;
    final path = res.files.single.path!;
    final ext = p.extension(path).toLowerCase();
    String text = '';
    if (ext == '.pdf') {
      final pdf = await PDFDoc.fromPath(path);
      text = await pdf.text;
    } else if (ext == '.docx') {
      text = await _extractDocxText(File(path));
    } else {
      text = await File(path).readAsString();
    }
    rawText = _normalizeText(text);
    _parse();
    notifyListeners();
  }

  Future<void> pasteText(String text) async {
    rawText = _normalizeText(text);
    _parse();
    notifyListeners();
  }

  void updateConfig(ParsingConfig newCfg) {
    config = newCfg;
    if (hasScript) {
      _parse();
      notifyListeners();
    }
  }

  void _parse() {
    blocks = parseScript(rawText ?? '', config);
    characters = blocks.map((b) => b.speaker).whereNotNull().toSet();
    acts = blocks.map((b) => b.act).whereNotNull().toSet().toList()..sort();
    scenes = blocks.map((b) => b.scene).whereNotNull().toSet().toList()..sort();
  }
}

class StudyModel extends ChangeNotifier {
  String? selectedCharacter;
  String scope = 'Tutto'; // Tutto | Atto | Scena
  String? selectedAct;
  String? selectedScene;
  StudyMode mode = StudyMode.readOthersWithPauses;
  int pauseSeconds = 3;
  double ttsRate = 0.9;
  bool slowPromptAfterPause = false;

  final FlutterTts tts = FlutterTts();
  final stt.SpeechToText sttEngine = stt.SpeechToText();
  bool speaking = false;
  bool listening = false;
  List<StudyItem> queue = [];
  int currentIndex = 0;
  List<LineResult> results = [];

  Future<void> initTts() async {
    await tts.setLanguage('it-IT');
    await tts.setSpeechRate(ttsRate);
    await tts.setPitch(1.0);
  }

  void setMode(StudyMode m){ mode = m; notifyListeners(); }
  void setCharacter(String? c){ selectedCharacter = c; notifyListeners(); }
  void setScope(String s){ scope = s; notifyListeners(); }
  void setAct(String? a){ selectedAct = a; notifyListeners(); }
  void setScene(String? s){ selectedScene = s; notifyListeners(); }
  void setPause(int s){ pauseSeconds = s; notifyListeners(); }
  void setTtsRate(double r){ ttsRate = r; tts.setSpeechRate(r); notifyListeners(); }
  void setSlowPrompt(bool v){ slowPromptAfterPause = v; notifyListeners(); }

  void buildQueue(List<ScriptBlock> blocks){
    Iterable<ScriptBlock> filtered = blocks;
    if (scope == 'Atto' && selectedAct != null) filtered = filtered.where((b)=> b.act == selectedAct);
    if (scope == 'Scena' && selectedScene != null) filtered = filtered.where((b)=> b.scene == selectedScene);
    queue = filtered.where((b)=> b.type == BlockType.dialogue).map((b)=> StudyItem(speaker: b.speaker ?? 'NARRATORE', text: b.text)).toList();
    currentIndex = 0;
    results.clear();
    notifyListeners();
  }

  Future<void> startSession() async {
    await initTts();
    currentIndex = 0; results.clear();
    speaking = false; listening = false;
    notifyListeners();
  }

  Future<void> stopAll() async {
    speaking = false; listening = false;
    await tts.stop();
    if (sttEngine.isListening) await sttEngine.stop();
    notifyListeners();
  }

  Future<void> next(BuildContext context) async {
    if (currentIndex >= queue.length) return;
    final item = queue[currentIndex];
    final isUserLine = selectedCharacter != null && item.speaker == selectedCharacter;

    if (mode == StudyMode.readAll) {
      await _speak('${item.speaker}: ${item.text}');
    } else if (mode == StudyMode.readOthersWithPauses) {
      if (!isUserLine) {
        await _speak('${item.speaker}: ${item.text}');
      } else {
        await _pauseAndOptionallyPrompt(item.text);
      }
    } else if (mode == StudyMode.verifyUser) {
      if (!isUserLine) {
        await _speak('${item.speaker}: ${item.text}');
      } else {
        await _listenAndScore(item.text, speaker: item.speaker);
      }
    }

    currentIndex++;
    notifyListeners();
  }

  Future<void> _pauseAndOptionallyPrompt(String target) async {
    speaking = false; notifyListeners();
    await Future.delayed(Duration(seconds: pauseSeconds));
    if (slowPromptAfterPause) {
      final prev = ttsRate;
      await tts.setSpeechRate(0.6);
      await _speak(target);
      await tts.setSpeechRate(prev);
    }
  }

  Future<void> _speak(String s) async {
    speaking = true; notifyListeners();
    await tts.speak(s);
    // Simple wait loop
    await Future.delayed(Duration(milliseconds: 400));
    speaking = false; notifyListeners();
  }

  Future<void> _listenAndScore(String target, {required String speaker}) async {
    results.removeWhere((r)=> r.index == currentIndex);
    final available = await sttEngine.initialize();
    if (!available){
      results.add(LineResult(index: currentIndex, speaker: speaker, expected: target, heard: '', accuracy: 0, errors: ['Riconoscimento vocale non disponibile']));
      return;
    }
    listening = true; notifyListeners();
    final completer = Completer<String>();
    final buffer = StringBuffer();
    sttEngine.listen(
      onResult: (res){
        if (res.finalResult){
          buffer.write(res.recognizedWords);
          completer.complete(buffer.toString());
        }
      },
      localeId: 'it_IT',
      listenMode: stt.ListenMode.dictation,
      pauseFor: Duration(seconds: pauseSeconds),
    );
    await Future.delayed(Duration(seconds: pauseSeconds + 4));
    await sttEngine.stop();
    final heard = await completer.future.timeout(const Duration(seconds: 2), onTimeout: ()=> buffer.toString());
    listening = false; notifyListeners();

    final score = compareUtterance(target, heard);
    results.add(LineResult(index: currentIndex, speaker: speaker, expected: target, heard: heard, accuracy: score.accuracy, errors: score.errors));
  }

  SessionReport buildReport(){
    if (results.isEmpty) return SessionReport(accuracy: 0, lines: []);
    final avg = results.map((r)=> r.accuracy).average;
    return SessionReport(accuracy: avg, lines: results);
  }
}

// ========================= ENTITIES =========================
enum BlockType { heading, dialogue, stageDirection, blank }
class ScriptBlock {
  final BlockType type;
  final String text;
  final String? speaker;
  final String? act;
  final String? scene;
  ScriptBlock({required this.type, required this.text, this.speaker, this.act, this.scene});
}

class ParsingConfig {
  bool upperCaseNames;
  bool initialCapitalAllowed;
  bool requiresColon;
  bool boldMarker;
  bool nameOnOwnLine;
  String? customRegex;
  String actPattern;
  String scenePattern;
  ParsingConfig({
    required this.upperCaseNames,
    required this.initialCapitalAllowed,
    required this.requiresColon,
    required this.boldMarker,
    required this.nameOnOwnLine,
    required this.actPattern,
    required this.scenePattern,
    this.customRegex,
  });
  factory ParsingConfig.defaults() => ParsingConfig(
    upperCaseNames: true,
    initialCapitalAllowed: true,
    requiresColon: true,
    boldMarker: false,
    nameOnOwnLine: true,
    actPattern: r'^(ATTO|ACT)\s+([IVXLC0-9]+)\b',
    scenePattern: r'^(SCENA|SCENE)\s+([IVXLC0-9]+)\b',
  );
  Map<String, dynamic> toJson() => {
    'upperCaseNames': upperCaseNames,
    'initialCapitalAllowed': initialCapitalAllowed,
    'requiresColon': requiresColon,
    'boldMarker': boldMarker,
    'nameOnOwnLine': nameOnOwnLine,
    'customRegex': customRegex,
    'actPattern': actPattern,
    'scenePattern': scenePattern,
  };
  factory ParsingConfig.fromJson(Map<String, dynamic> j) => ParsingConfig(
    upperCaseNames: j['upperCaseNames'] ?? true,
    initialCapitalAllowed: j['initialCapitalAllowed'] ?? true,
    requiresColon: j['requiresColon'] ?? true,
    boldMarker: j['boldMarker'] ?? false,
    nameOnOwnLine: j['nameOnOwnLine'] ?? true,
    customRegex: j['customRegex'],
    actPattern: j['actPattern'] ?? r'^(ATTO|ACT)\s+([IVXLC0-9]+)\b',
    scenePattern: j['scenePattern'] ?? r'^(SCENA|SCENE)\s+([IVXLC0-9]+)\b',
  );
}

class StudyItem { final String speaker; final String text; StudyItem({required this.speaker, required this.text}); }
class LineResult {
  final int index;
  final String speaker;
  final String expected;
  final String heard;
  final double accuracy;
  final List<String> errors;
  LineResult({required this.index, required this.speaker, required this.expected, required this.heard, required this.accuracy, required this.errors});
}
class SessionReport { final double accuracy; final List<LineResult> lines; SessionReport({required this.accuracy, required this.lines}); }
enum StudyMode { readAll, readOthersWithPauses, verifyUser }

// ========================= PARSER =========================
List<ScriptBlock> parseScript(String text, ParsingConfig cfg){
  final lines = const LineSplitter().convert(text);
  final blocks = <ScriptBlock>[];
  String? currentAct; String? currentScene;

  final actRe = RegExp(cfg.actPattern, caseSensitive: false);
  final sceneRe = RegExp(cfg.scenePattern, caseSensitive: false);
  final nameRe = _buildNameRegex(cfg);

  for (final raw in lines){
    final line = raw.trimRight();
    if (line.trim().isEmpty){
      blocks.add(ScriptBlock(type: BlockType.blank, text: '', act: currentAct, scene: currentScene));
      continue;
    }
    if (actRe.hasMatch(line)){
      currentAct = actRe.firstMatch(line)!.group(0);
      blocks.add(ScriptBlock(type: BlockType.heading, text: line, act: currentAct, scene: currentScene));
      continue;
    }
    if (sceneRe.hasMatch(line)){
      currentScene = sceneRe.firstMatch(line)!.group(0);
      blocks.add(ScriptBlock(type: BlockType.heading, text: line, act: currentAct, scene: currentScene));
      continue;
    }
    final m = nameRe.firstMatch(line);
    if (m != null && m.start == 0){
      final speaker = _cleanSpeaker(m.group(1)!);
      final after = line.substring(m.end).trimLeft();
      blocks.add(ScriptBlock(type: BlockType.dialogue, text: after, speaker: speaker, act: currentAct, scene: currentScene));
      continue;
    }
    if (RegExp(r'^[\(\[].*[\)\]]\.?$').hasMatch(line)){
      blocks.add(ScriptBlock(type: BlockType.stageDirection, text: line, act: currentAct, scene: currentScene));
      continue;
    }
    if (blocks.isNotEmpty && blocks.last.type == BlockType.dialogue && blocks.last.text.isEmpty){
      final last = blocks.removeLast();
      blocks.add(ScriptBlock(type: BlockType.dialogue, text: line, speaker: last.speaker, act: last.act, scene: last.scene));
      continue;
    }
    blocks.add(ScriptBlock(type: BlockType.stageDirection, text: line, act: currentAct, scene: currentScene));
  }
  return blocks;
}

RegExp _buildNameRegex(ParsingConfig cfg){
  if ((cfg.customRegex ?? '').trim().isNotEmpty){
    return RegExp(cfg.customRegex!);
  }
  final nameToken = cfg.upperCaseNames
      ? r'([A-ZÀ-Ý][A-ZÀ-Ý\s\.-]{1,30})'
      : cfg.initialCapitalAllowed
          ? r'([A-ZÀ-Ý][a-zà-ÿA-ZÀ-Ý\-\.]{1,30}(?:\s+[A-ZÀ-Ý][a-zà-ÿA-ZÀ-Ý\-\.]{1,30})*)'
          : r'([A-Za-zÀ-ÿ]{2,30})';
  final bold = cfg.boldMarker ? r'\*\*' : '';
  final colon = cfg.requiresColon ? ':' : '';
  final pattern = '^' + bold + nameToken + bold + r'\s*' + colon;
  return RegExp(pattern);
}
String _cleanSpeaker(String s)=> s.replaceAll('*','').replaceAll(':','').trim();
String _normalizeText(String t)=> t.replaceAll('\r\n','\n').replaceAll('\r','\n');

Future<String> _extractDocxText(File file) async {
  final bytes = await file.readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  final entry = archive.files.firstWhere((f)=> f.name == 'word/document.xml');
  final xmlStr = utf8.decode(entry.content as List<int>);
  final doc = XmlDocument.parse(xmlStr);
  final buffer = StringBuffer();
  for (final p in doc.findAllElements('w:p')){
    final textNodes = p.findAllElements('w:t');
    final parts = textNodes.map((e)=> e.text).join('');
    buffer.writeln(parts);
  }
  return buffer.toString();
}

// ========================= SCORING =========================
class CompareScore { final double accuracy; final List<String> errors; CompareScore(this.accuracy, this.errors); }

CompareScore compareUtterance(String expected, String heard){
  final exp = _tokenize(expected);
  final got = _tokenize(heard);
  if (exp.isEmpty) return CompareScore(0, ['Nessun testo atteso']);
  final m = exp.length, n = got.length;
  final dp = List.generate(m+1, (_)=> List<int>.filled(n+1, 0));
  for (var i=0;i<=m;i++) dp[i][0]=i;
  for (var j=0;j<=n;j++) dp[0][j]=j;
  for (var i=1;i<=m;i++){
    for (var j=1;j<=n;j++){
      final cost = exp[i-1]==got[j-1]?0:1;
      dp[i][j] = [dp[i-1][j]+1, dp[i][j-1]+1, dp[i-1][j-1]+cost].reduce((a,b)=> a<b?a:b);
    }
  }
  final wer = dp[m][n]/m;
  final accuracy = ((1-wer)*100).clamp(0,100).toDouble();

  final errors = <String>[];
  var i=m, j=n;
  while (i>0 || j>0){
    if (i>0 && dp[i][j] == dp[i-1][j]+1){ errors.add('Mancante: "${exp[i-1]}"'); i--; }
    else if (j>0 && dp[i][j] == dp[i][j-1]+1){ errors.add('In più: "${got[j-1]}"'); j--; }
    else { if (exp[i-1]!=got[j-1]) errors.add('Sostituito: "${exp[i-1]}" → "${got[j-1]}"'); i--; j--; }
  }
  errors.reverse();
  return CompareScore(accuracy, errors);
}

List<String> _tokenize(String s){
  final clean = s.toLowerCase()
    .replaceAll(RegExp(r"[.,;:!\?\(\)\[\]\{\}\-–—'\"“”]"), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
  if (clean.isEmpty) return [];
  return clean.split(' ');
}

// ========================= UI =========================
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final script = context.watch<ScriptModel>();
    return Scaffold(
      appBar: AppBar(title: const Text('Script Learner')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            ElevatedButton.icon(
              onPressed: () => script.loadFromFile(),
              icon: const Icon(Icons.upload_file),
              label: const Text('Importa PDF / DOCX / TXT'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                final text = await _showPasteDialog(context);
                if (text != null) await script.pasteText(text);
              },
              icon: const Icon(Icons.paste),
              label: const Text('Incolla testo'),
            ),
            ElevatedButton.icon(
              onPressed: script.hasScript ? () async {
                final cfg = await Navigator.push(context, MaterialPageRoute(builder: (_) => ConfigScreen(initial: script.config)));
                if (cfg is ParsingConfig) script.updateConfig(cfg);
              } : null,
              icon: const Icon(Icons.rule),
              label: const Text('Regole di formattazione'),
            ),
          ]),
          const SizedBox(height: 12),
          if (!script.hasScript)
            const Text('Importa un copione per iniziare.', style: TextStyle(fontSize: 16))
          else
            Expanded(
              child: Row(children: [
                Flexible(flex: 2, child: _ScriptPreview()),
                const SizedBox(width: 12),
                Flexible(flex: 1, child: _StudyPanel()),
              ]),
            ),
        ]),
      ),
      floatingActionButton: script.hasScript ? FloatingActionButton.extended(
        onPressed: () async {
          final study = context.read<StudyModel>();
          study.buildQueue(script.blocks);
          await study.startSession();
          if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => const SessionScreen()));
        },
        icon: const Icon(Icons.play_arrow),
        label: const Text('Avvia sessione'),
      ) : null,
    );
  }
}

class _ScriptPreview extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final script = context.watch<ScriptModel>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Anteprima copione', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _ChipList(title: 'Personaggi', items: script.characters.toList()..sort()),
            _ChipList(title: 'Atti', items: script.acts),
            _ChipList(title: 'Scene', items: script.scenes),
          ]),
          const Divider(),
          Expanded(
            child: ListView.builder(
              itemCount: script.blocks.length.clamp(0, 400),
              itemBuilder: (_, i){
                final b = script.blocks[i];
                Color? c; IconData ic = Icons.notes;
                if (b.type == BlockType.dialogue){ c = Colors.green[50]; ic = Icons.record_voice_over; }
                else if (b.type == BlockType.heading){ c = Colors.blue[50]; ic = Icons.title; }
                else if (b.type == BlockType.stageDirection){ c = Colors.amber[50]; ic = Icons.theater_comedy; }
                return Container(
                  color: c,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  child: ListTile(
                    dense: true,
                    leading: Icon(ic),
                    title: Text(b.type == BlockType.dialogue ? (b.speaker ?? '???') : b.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: b.type == BlockType.dialogue ? Text(b.text) : null,
                    trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      if (b.act != null) Text(b.act!, style: const TextStyle(fontSize: 12)),
                      if (b.scene != null) Text(b.scene!, style: const TextStyle(fontSize: 12)),
                    ]),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

class _ChipList extends StatelessWidget {
  final String title; final List<String> items;
  const _ChipList({required this.title, required this.items});
  @override
  Widget build(BuildContext context) {
    final sorted = [...items]; sorted.sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Wrap(spacing: 6, children: sorted.take(20).map((e)=> Chip(label: Text(e))).toList()),
    ]);
  }
}

class _StudyPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final script = context.watch<ScriptModel>();
    final study = context.watch<StudyModel>();
    final chars = ['(scegli)'] + (script.characters.toList()..sort());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Studio', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          DropdownButton<String>(
            isExpanded: true,
            value: study.selectedCharacter ?? '(scegli)',
            items: chars.map((c)=> DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v){
              if (v == null) return;
              context.read<StudyModel>().setCharacter(v == '(scegli)' ? null : v);
            },
          ),
          const SizedBox(height: 8),
          DropdownButton<String>(
            isExpanded: true,
            value: study.scope,
            items: const [
              DropdownMenuItem(value: 'Tutto', child: Text('Tutto')),
              DropdownMenuItem(value: 'Atto', child: Text('Per Atto')),
              DropdownMenuItem(value: 'Scena', child: Text('Per Scena')),
            ],
            onChanged: (v)=> context.read<StudyModel>().setScope(v!),
          ),
          if (study.scope == 'Atto')
            DropdownButton<String>(
              isExpanded: true,
              value: study.selectedAct,
              hint: const Text('Seleziona Atto'),
              items: context.read<ScriptModel>().acts.map((a)=> DropdownMenuItem(value: a, child: Text(a))).toList(),
              onChanged: (v)=> context.read<StudyModel>().setAct(v),
            ),
          if (study.scope == 'Scena')
            DropdownButton<String>(
              isExpanded: true,
              value: study.selectedScene,
              hint: const Text('Seleziona Scena'),
              items: context.read<ScriptModel>().scenes.map((s)=> DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v)=> context.read<StudyModel>().setScene(v),
            ),
          const Divider(),
          const Text('Modalità'),
          const SizedBox(height: 4),
          ToggleButtons(
            isSelected: [
              study.mode == StudyMode.readAll,
              study.mode == StudyMode.readOthersWithPauses,
              study.mode == StudyMode.verifyUser
            ],
            onPressed: (i)=> context.read<StudyModel>().setMode(StudyMode.values[i]),
            children: const [
              Padding(padding: EdgeInsets.all(8), child: Text('Legge tutto')),
              Padding(padding: EdgeInsets.all(8), child: Text('Solo altri + pause')),
              Padding(padding: EdgeInsets.all(8), child: Text('Verifica utente')),
            ],
          ),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Pausa (s) '),
            Expanded(child: Slider(
              value: study.pauseSeconds.toDouble(), min: 1, max: 8, divisions: 7,
              label: study.pauseSeconds.toString(),
              onChanged: (v)=> context.read<StudyModel>().setPause(v.round()),
            )),
          ]),
          Row(children: [
            const Text('Velocità voce '),
            Expanded(child: Slider(
              value: study.ttsRate, min: 0.5, max: 1.2, divisions: 7,
              label: study.ttsRate.toStringAsFixed(2),
              onChanged: (v)=> context.read<StudyModel>().setTtsRate(v),
            )),
          ]),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: study.slowPromptAfterPause,
            onChanged: (v)=> context.read<StudyModel>().setSlowPrompt(v ?? false),
            title: const Text('Dopo la pausa, leggi lentamente la battuta (prompt)'),
          ),
          const Spacer(),
          const Text('Suggerimento: usa "Verifica utente" per il punteggio.'),
        ]),
      ),
    );
  }
}

class ConfigScreen extends StatefulWidget {
  final ParsingConfig initial;
  const ConfigScreen({super.key, required this.initial});
  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}
class _ConfigScreenState extends State<ConfigScreen> {
  late ParsingConfig cfg;
  final customCtrl = TextEditingController();
  final actCtrl = TextEditingController();
  final sceneCtrl = TextEditingController();
  @override
  void initState() {
    super.initState();
    cfg = widget.initial;
    customCtrl.text = cfg.customRegex ?? '';
    actCtrl.text = cfg.actPattern;
    sceneCtrl.text = cfg.scenePattern;
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Regole di formattazione')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Modalità guidata', style: TextStyle(fontWeight: FontWeight.bold)),
          SwitchListTile(title: const Text('Nomi in MAIUSCOLO'), value: cfg.upperCaseNames,
            onChanged: (v)=> setState(()=> cfg = ParsingConfig.fromJson({...cfg.toJson(),'upperCaseNames': v}))),
          SwitchListTile(title: const Text('Consenti Iniziale maiuscola'), value: cfg.initialCapitalAllowed,
            onChanged: (v)=> setState(()=> cfg = ParsingConfig.fromJson({...cfg.toJson(),'initialCapitalAllowed': v}))),
          SwitchListTile(title: const Text('Richiede ":" dopo il nome'), value: cfg.requiresColon,
            onChanged: (v)=> setState(()=> cfg = ParsingConfig.fromJson({...cfg.toJson(),'requiresColon': v}))),
          SwitchListTile(title: const Text('Nome in grassetto (Markdown **NOME**)'), value: cfg.boldMarker,
            onChanged: (v)=> setState(()=> cfg = ParsingConfig.fromJson({...cfg.toJson(),'boldMarker': v}))),
          SwitchListTile(title: const Text('Nome su riga dedicata'), value: cfg.nameOnOwnLine,
            onChanged: (v)=> setState(()=> cfg = ParsingConfig.fromJson({...cfg.toJson(),'nameOnOwnLine': v}))),
          const SizedBox(height: 8),
          const Divider(),
          const Text('Pattern Atto / Scena (regex)'),
          TextField(controller: actCtrl, decoration: const InputDecoration(labelText: 'Pattern Atto')),
          TextField(controller: sceneCtrl, decoration: const InputDecoration(labelText: 'Pattern Scena')),
          const SizedBox(height: 8),
          const Divider(),
          const Text('Regex personalizzata (sovrascrive le opzioni guidate)'),
          TextField(controller: customCtrl, decoration: const InputDecoration(hintText: r'Es. ^([A-Z ]+):')),
          const SizedBox(height: 12),
          Row(children: [
            ElevatedButton.icon(onPressed: (){ Navigator.pop(context, cfg); }, icon: const Icon(Icons.save), label: const Text('Salva')),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: (){
                final newCfg = ParsingConfig.fromJson({
                  ...cfg.toJson(),
                  'customRegex': customCtrl.text.trim().isEmpty ? null : customCtrl.text.trim(),
                  'actPattern': actCtrl.text.trim(),
                  'scenePattern': sceneCtrl.text.trim(),
                });
                Navigator.pop(context, newCfg);
              },
              icon: const Icon(Icons.rule_folder), label: const Text('Applica Regex/Pattern'),
            ),
          ]),
        ]),
      ),
    );
  }
}

Future<String?> _showPasteDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  return showDialog<String>(context: context, builder: (_) {
    return AlertDialog(
      title: const Text('Incolla testo copione'),
      content: SizedBox(width: 600, child: TextField(controller: ctrl, maxLines: 12, decoration: const InputDecoration(border: OutlineInputBorder()))),
      actions: [
        TextButton(onPressed: ()=> Navigator.pop(context), child: const Text('Annulla')),
        ElevatedButton(onPressed: ()=> Navigator.pop(context, ctrl.text), child: const Text('Usa testo')),
      ],
    );
  });
}

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}
class _SessionScreenState extends State<SessionScreen> {
  @override
  Widget build(BuildContext context) {
    final study = context.watch<StudyModel>();
    return Scaffold(
      appBar: AppBar(title: const Text('Sessione di studio'), actions: [
        IconButton(onPressed: ()=> study.stopAll(), icon: const Icon(Icons.stop)),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ElevatedButton.icon(onPressed: ()=> study.next(context), icon: const Icon(Icons.skip_next), label: const Text('Prossima battuta')),
            const SizedBox(width: 12),
            if (study.speaking) const Chip(label: Text('Parlando...')),
            if (study.listening) const Chip(label: Text('Ascoltando...')),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: study.results.length,
              itemBuilder: (_, i){
                final r = study.results[i];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${r.speaker} – accuracy ${r.accuracy.toStringAsFixed(1)}%'),
                      const SizedBox(height: 6),
                      Text('Atteso: ${r.expected}'),
                      const SizedBox(height: 4),
                      Text('Detto:  ${r.heard}'),
                      if (r.errors.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        const Text('Errori', style: TextStyle(fontWeight: FontWeight.bold)),
                        ...r.errors.map((e)=> Text('• $e')),
                      ],
                    ]),
                  ),
                );
              },
            ),
          ),
          const Divider(),
          Builder(builder: (ctx){
            final report = study.buildReport();
            return Text('Punteggio medio: ${report.accuracy.toStringAsFixed(1)}%');
          }),
        ]),
      ),
    );
  }
}
