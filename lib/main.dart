import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

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

class _CropDocumentScreen extends StatefulWidget {
  const _CropDocumentScreen({required this.imagePath});

  final String imagePath;

  @override
  State<_CropDocumentScreen> createState() => _CropDocumentScreenState();
}

class _CropDocumentScreenState extends State<_CropDocumentScreen> {
  List<Offset>? _corners;
  Size? _viewSize;

  static const double _handleSize = 20;
  static const double _minEdge = 30;

  /// Order: topLeft, topRight, bottomRight, bottomLeft
  void _initCorners(double width, double height) {
    final margin = 0.1;
    _corners ??= [
      Offset(width * margin, height * margin),
      Offset(width * (1 - margin), height * margin),
      Offset(width * (1 - margin), height * (1 - margin)),
      Offset(width * margin, height * (1 - margin)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Match card corners'),
        actions: [
          TextButton(
            onPressed: () async {
              if (_viewSize == null || _corners == null) {
                Navigator.of(context).pop<File?>(null);
                return;
              }
              final cropped = await _cropAndEnhance();
              Navigator.of(context).pop<File?>(cropped);
            },
            child: const Text('Done'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final height = constraints.maxHeight;
                _viewSize ??= Size(width, height);
                _initCorners(width, height);
                final corners = _corners!;

                return Stack(
                  children: [
                    Positioned.fill(
                      child: Image.file(
                        File(widget.imagePath),
                        fit: BoxFit.fill,
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _QuadOverlayPainter(corners: corners),
                        ),
                      ),
                    ),
                    _buildHandle(corners[0], (delta) =>
                        _moveCorner(0, delta)),
                    _buildHandle(corners[1], (delta) =>
                        _moveCorner(1, delta)),
                    _buildHandle(corners[2], (delta) =>
                        _moveCorner(2, delta)),
                    _buildHandle(corners[3], (delta) =>
                        _moveCorner(3, delta)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _moveCorner(int index, Offset delta) {
    final size = _viewSize!;
    setState(() {
      final c = _corners![index];
      _corners![index] = Offset(
        (c.dx + delta.dx).clamp(0.0, size.width),
        (c.dy + delta.dy).clamp(0.0, size.height),
      );
    });
  }

  /// Detects tilt angle (degrees) from text block orientation in the cropped image.
  Future<double> _detectTiltAngle(img.Image image) async {
    final dir = await getTemporaryDirectory();
    final tempPath =
        '${dir.path}/_tilt_${DateTime.now().millisecondsSinceEpoch}.png';
    final tempFile = File(tempPath);
    try {
      await tempFile.writeAsBytes(img.encodePng(image));
      final inputImage = InputImage.fromFilePath(tempPath);
      final recognizer = TextRecognizer();
      final result = await recognizer.processImage(inputImage);
      recognizer.close();

      double sumDeg = 0;
      int count = 0;
      for (final block in result.blocks) {
        final pts = block.cornerPoints;
        if (pts != null && pts.length >= 2) {
          final p0 = pts[0];
          final p1 = pts[1];
          final dx = (p1.x - p0.x).toDouble();
          final dy = (p1.y - p0.y).toDouble();
          final angleRad = math.atan2(dy, dx);
          final angleDeg = angleRad * 180 / math.pi;
          sumDeg += angleDeg;
          count++;
        }
      }
      if (count == 0) return 0;
      return sumDeg / count;
    } catch (_) {
      return 0;
    } finally {
      if (await tempFile.exists()) await tempFile.delete();
    }
  }

  Widget _buildHandle(Offset position, void Function(Offset delta) onDrag) {
    return Positioned(
      left: position.dx - _handleSize / 2,
      top: position.dy - _handleSize / 2,
      child: GestureDetector(
        onPanUpdate: (details) {
          onDrag(details.delta);
        },
        child: Container(
          width: _handleSize,
          height: _handleSize,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.blue, width: 2),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Future<File?> _cropAndEnhance() async {
    final corners = _corners!;
    final size = _viewSize!;

    final bytes = await File(widget.imagePath).readAsBytes();
    final original = img.decodeImage(bytes);
    if (original == null) return null;

    final scaleX = original.width / size.width;
    final scaleY = original.height / size.height;

    final srcQuad = corners.map((o) => Offset(o.dx * scaleX, o.dy * scaleY)).toList();

    final w1 = _dist(srcQuad[0], srcQuad[1]);
    final w2 = _dist(srcQuad[3], srcQuad[2]);
    final h1 = _dist(srcQuad[0], srcQuad[3]);
    final h2 = _dist(srcQuad[1], srcQuad[2]);
    final outW = (math.max(w1, w2)).round().clamp(1, original.width);
    final outH = (math.max(h1, h2)).round().clamp(1, original.height);

    img.Image? work = _perspectiveWarp(original, srcQuad, outW, outH);
    if (work == null) return null;

    final tiltAngle = await _detectTiltAngle(work);
    if (tiltAngle.abs() > 0.5) {
      work = img.copyRotate(work, angle: -tiltAngle);
    }

    final gray = img.grayscale(work);
    final enhanced = img.adjustColor(gray, contrast: 1.2);

    final dir = await getTemporaryDirectory();
    final outPath =
        '${dir.path}/scan_${DateTime.now().millisecondsSinceEpoch}.png';
    final outFile = File(outPath);
    await outFile.writeAsBytes(img.encodePng(enhanced));
    return outFile;
  }

  double _dist(Offset a, Offset b) {
    return math.sqrt((a.dx - b.dx) * (a.dx - b.dx) + (a.dy - b.dy) * (a.dy - b.dy));
  }

  /// Warps source image so quad (topLeft, topRight, bottomRight, bottomLeft) becomes a straight rectangle.
  img.Image? _perspectiveWarp(
      img.Image src, List<Offset> quad, int outW, int outH) {
    if (quad.length != 4) return null;
    final x0 = quad[0].dx;
    final y0 = quad[0].dy;
    final x1 = quad[1].dx;
    final y1 = quad[1].dy;
    final x2 = quad[2].dx;
    final y2 = quad[2].dy;
    final x3 = quad[3].dx;
    final y3 = quad[3].dy;
    final W = outW.toDouble();
    final H = outH.toDouble();

    final A = <List<double>>[
      [0, 0, 1, 0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 1, 0, 0],
      [W, 0, 1, 0, 0, 0, -x1 * W, -x1 * 0],
      [0, 0, 0, W, 0, 1, -y1 * W, -y1 * 0],
      [W, H, 1, 0, 0, 0, -x2 * W, -x2 * H],
      [0, 0, 0, W, H, 1, -y2 * W, -y2 * H],
      [0, H, 1, 0, 0, 0, -x3 * 0, -x3 * H],
      [0, 0, 0, 0, H, 1, -y3 * 0, -y3 * H],
    ];
    final b = [x0, y0, x1, y1, x2, y2, x3, y3];
    final h = _solve8(A, b);
    if (h == null) return null;

    final out = img.Image(width: outW, height: outH);
    final sw = src.width - 1;
    final sh = src.height - 1;
    for (var v = 0; v < outH; v++) {
      for (var u = 0; u < outW; u++) {
        final uu = u.toDouble();
        final vv = v.toDouble();
        final den = h[6] * uu + h[7] * vv + 1;
        if (den.abs() < 1e-10) continue;
        final x = (h[0] * uu + h[1] * vv + h[2]) / den;
        final y = (h[3] * uu + h[4] * vv + h[5]) / den;
        if (x < 0 || x > sw || y < 0 || y > sh) continue;
        final px = _bilinearSample(src, x, y);
        out.setPixel(u, v, px);
      }
    }
    return out;
  }

  List<double>? _solve8(List<List<double>> A, List<double> b) {
    final n = 8;
    final a = List.generate(n, (i) => List<double>.from(A[i])..add(b[i]));
    for (var col = 0; col < n; col++) {
      var maxRow = col;
      for (var row = col + 1; row < n; row++) {
        if (a[row][col].abs() > a[maxRow][col].abs()) maxRow = row;
      }
      final tmp = a[col];
      a[col] = a[maxRow];
      a[maxRow] = tmp;
      if (a[col][col].abs() < 1e-12) return null;
      final pivot = a[col][col];
      for (var j = 0; j <= n; j++) a[col][j] /= pivot;
      for (var row = 0; row < n; row++) {
        if (row == col) continue;
        final f = a[row][col];
        for (var j = 0; j <= n; j++) a[row][j] -= f * a[col][j];
      }
    }
    return List.generate(n, (i) => a[i][n]);
  }

  img.Color _bilinearSample(img.Image src, double x, double y) {
    final x0 = x.floor().clamp(0, src.width - 1);
    final y0 = y.floor().clamp(0, src.height - 1);
    final x1 = (x0 + 1).clamp(0, src.width - 1);
    final y1 = (y0 + 1).clamp(0, src.height - 1);
    final fx = x - x0;
    final fy = y - y0;
    final p00 = src.getPixel(x0, y0);
    final p10 = src.getPixel(x1, y0);
    final p01 = src.getPixel(x0, y1);
    final p11 = src.getPixel(x1, y1);
    final r = (p00.r * (1 - fx) * (1 - fy) +
            p10.r * fx * (1 - fy) +
            p01.r * (1 - fx) * fy +
            p11.r * fx * fy)
        .round()
        .clamp(0, 255);
    final g = (p00.g * (1 - fx) * (1 - fy) +
            p10.g * fx * (1 - fy) +
            p01.g * (1 - fx) * fy +
            p11.g * fx * fy)
        .round()
        .clamp(0, 255);
    final b = (p00.b * (1 - fx) * (1 - fy) +
            p10.b * fx * (1 - fy) +
            p01.b * (1 - fx) * fy +
            p11.b * fx * fy)
        .round()
        .clamp(0, 255);
    final a = (p00.a * (1 - fx) * (1 - fy) +
            p10.a * fx * (1 - fy) +
            p01.a * (1 - fx) * fy +
            p11.a * fx * fy)
        .round()
        .clamp(0, 255);
    return img.ColorRgba8(r, g, b, a);
  }
}

class _QuadOverlayPainter extends CustomPainter {
  _QuadOverlayPainter({required this.corners});

  final List<Offset> corners;

  @override
  void paint(Canvas canvas, Size size) {
    final overlayPaint = Paint()..color = Colors.black.withOpacity(0.5);
    canvas.drawRect(Offset.zero & size, overlayPaint);

    final path = Path()..moveTo(corners[0].dx, corners[0].dy);
    for (var i = 1; i < corners.length; i++) {
      path.lineTo(corners[i].dx, corners[i].dy);
    }
    path.close();

    final clearPaint = Paint()..blendMode = BlendMode.clear;
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawPath(path, clearPaint);
    canvas.restore();

    final borderPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
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

      // Let user adjust document corners before OCR.
      final File? croppedFile = await Navigator.of(context).push<File?>(
        MaterialPageRoute(
          builder: (_) => _CropDocumentScreen(imagePath: pickedFile.path),
        ),
      );

      if (croppedFile == null) {
        return;
      }

      setState(() {
        _isProcessing = true;
        _recognizedText = '';
        _detectedTitle = null;
        _matchPercent = null;
        _isTitleMatch = null;
        _imageFile = XFile(croppedFile.path);
      });

      final inputImage = InputImage.fromFilePath(croppedFile.path);
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
