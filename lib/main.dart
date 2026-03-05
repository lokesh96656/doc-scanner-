import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final ImagePicker _picker = ImagePicker();
  final TextRecognizer _textRecognizer = TextRecognizer();
  final TextEditingController _titleController = TextEditingController();

  String _recognizedText = '';
  bool _isProcessing = false;
  XFile? _imageFile;
  String? _detectedTitle;
  double? _matchPercent;
  bool? _isTitleMatch;

  @override
  void dispose() {
    _titleController.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  String? _extractTitle(String text) {
    final lines = text.split('\n');
    final regex = RegExp(
      r'title\s*:\s*(.+)',
      caseSensitive: false,
    );
    for (final line in lines) {
      final match = regex.firstMatch(line);
      if (match != null) {
        return match.group(1)?.trim();
      }
    }
    return null;
  }

  void _updateMatch() {
    final expected = _titleController.text.trim();
    final detected = _detectedTitle?.trim() ?? '';

    if (expected.isEmpty || detected.isEmpty) {
      setState(() {
        _matchPercent = null;
        _isTitleMatch = null;
      });
      return;
    }

    final similarity =
        _calculateSimilarity(expected.toLowerCase(), detected.toLowerCase());

    setState(() {
      _matchPercent = similarity * 100;
      _isTitleMatch = similarity >= 0.8;
    });
  }

  double _calculateSimilarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) {
      return 1.0;
    }
    if (a.isEmpty || b.isEmpty) {
      return 0.0;
    }

    final m = a.length;
    final n = b.length;
    final dp = List.generate(
      m + 1,
      (_) => List<int>.filled(n + 1, 0),
    );

    for (var i = 0; i <= m; i++) {
      dp[i][0] = i;
    }
    for (var j = 0; j <= n; j++) {
      dp[0][j] = j;
    }

    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        dp[i][j] = [
          dp[i - 1][j] + 1,
          dp[i][j - 1] + 1,
          dp[i - 1][j - 1] + cost,
        ].reduce((value, element) => value < element ? value : element);
      }
    }

    final distance = dp[m][n];
    final maxLen = m > n ? m : n;
    return 1.0 - distance / maxLen;
  }

  Future<void> _scanDocument() async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
      );

      if (pickedFile == null) {
        return;
      }

      setState(() {
        _isProcessing = true;
        _recognizedText = '';
        _imageFile = pickedFile;
      });

      final inputImage = InputImage.fromFilePath(pickedFile.path);
      final RecognizedText recognizedText =
          await _textRecognizer.processImage(inputImage);

      setState(() {
        _recognizedText = recognizedText.text;
        _detectedTitle = _extractTitle(recognizedText.text);
        _isProcessing = false;
      });
      _updateMatch();
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _recognizedText = 'Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OCR Document Scanner'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.camera_alt),
              label: const Text('Scan Document'),
              onPressed: _isProcessing ? null : _scanDocument,
            ),
            const SizedBox(height: 16),
            if (_isProcessing) const CircularProgressIndicator(),
            if (_imageFile != null && !_isProcessing) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: 200,
                child: Image.file(File(_imageFile!.path)),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Enter expected title',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _updateMatch(),
            ),
            const SizedBox(height: 12),
            if (_detectedTitle != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Detected title: $_detectedTitle',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              )
            else if (_recognizedText.isNotEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('No "Title:" section found in image.'),
              ),
            const SizedBox(height: 8),
            if (_matchPercent != null && _isTitleMatch != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Match: ${_isTitleMatch! ? 'True' : 'False'} '
                  '(${_matchPercent!.toStringAsFixed(1)}%)',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _isTitleMatch! ? Colors.green : Colors.red,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  _recognizedText.isEmpty
                      ? 'Captured text will appear here.'
                      : _recognizedText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
