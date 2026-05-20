import 'dart:io';
import 'dart:math' as math;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'face/face_match_service.dart';

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

String _normalizeOcr(String s) {
  // Keep it simple: normalize whitespace and uppercase for keyword checks.
  return s.replaceAll('\r', '\n').replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

RegExp _jsonRegex(String pattern, {bool defaultCaseSensitive = false}) {
  // Accept optional leading inline flags used in JSON patterns: (?i), (?m), (?im), (?mi)
  // and translate them to Dart RegExp options.
  var p = pattern;
  var caseSensitive = defaultCaseSensitive;
  var multiLine = false;

  final m = RegExp(r'^\(\?([im]+)\)').firstMatch(pattern);
  if (m != null) {
    final flags = m.group(1)!;
    caseSensitive = !flags.contains('i');
    multiLine = flags.contains('m');
    p = pattern.substring(m.end);
  }

  try {
    return RegExp(p, caseSensitive: caseSensitive, multiLine: multiLine);
  } catch (_) {
    // Keep engine alive even if one bad pattern slips into JSON.
    return RegExp(r'$.');
  }
}

class _JsonTemplateEngine {
  _JsonTemplateEngine(this.templates);

  final List<_JsonTemplate> templates;

  static Future<_JsonTemplateEngine> loadFromAssets() async {
    final raw = await rootBundle.loadString(
      'assets/templates/id_templates.json',
    );
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final list = (map['templates'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
    final templates = list.map(_JsonTemplate.fromJson).toList(growable: false);
    return _JsonTemplateEngine(templates);
  }

  _JsonTemplateResult detect(String ocrText) {
    final normalized = _normalizeOcr(ocrText);
    final upper = normalized.toUpperCase();

    _JsonTemplate? bestQualified;
    int bestQualifiedScore = -1;
    _JsonTemplate? bestAny;
    int bestAnyScore = -1;
    for (final t in templates) {
      final score = t.score(upper);
      if (score > bestAnyScore) {
        bestAnyScore = score;
        bestAny = t;
      }
      if (score >= t.minScore && score > bestQualifiedScore) {
        bestQualifiedScore = score;
        bestQualified = t;
      }
    }

    final selected = bestQualified ?? (bestAnyScore >= 2 ? bestAny : null);
    if (selected == null) {
      return const _JsonTemplateResult(
        displayName: 'Unknown',
        fields: {},
        valid: {},
      );
    }

    final fields = selected.extract(normalized);
    final valid = selected.validate(fields);
    return _JsonTemplateResult(
      displayName: selected.displayName,
      fields: fields,
      valid: valid,
    );
  }
}

class _JsonTemplateResult {
  const _JsonTemplateResult({
    required this.displayName,
    required this.fields,
    required this.valid,
  });

  final String displayName;
  final Map<String, String> fields;
  final Map<String, bool> valid;
}

class _JsonTemplate {
  _JsonTemplate({
    required this.id,
    required this.displayName,
    required this.minScore,
    required this.keywordRules,
    required this.regexRules,
    required this.extractRules,
    required this.validateRules,
  });

  final String id;
  final String displayName;
  final int minScore;
  final List<_JsonKeywordRule> keywordRules;
  final List<_JsonRegexRule> regexRules;
  final Map<String, _JsonExtractRule> extractRules;
  final Map<String, RegExp> validateRules;

  factory _JsonTemplate.fromJson(Map<String, dynamic> j) {
    final detect = Map<String, dynamic>.from(j['detect'] as Map? ?? const {});
    final minScore = (detect['minScore'] as num? ?? 0).toInt();
    final keywords = (detect['keywords'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map(
          (k) => _JsonKeywordRule(
            text: k['text'] as String,
            weight: (k['weight'] as num).toInt(),
          ),
        )
        .toList(growable: false);
    final regex = (detect['regex'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map(
          (r) => _JsonRegexRule(
            re: _jsonRegex(r['pattern'] as String),
            weight: (r['weight'] as num).toInt(),
          ),
        )
        .toList(growable: false);

    final extract = Map<String, dynamic>.from(j['extract'] as Map? ?? const {})
        .map(
          (k, v) => MapEntry(
            k,
            _JsonExtractRule.fromJson(Map<String, dynamic>.from(v as Map)),
          ),
        );

    final validate =
        Map<String, dynamic>.from(j['validate'] as Map? ?? const {}).map(
          (k, v) => MapEntry(
            k,
            _jsonRegex(Map<String, dynamic>.from(v as Map)['regex'] as String),
          ),
        );

    return _JsonTemplate(
      id: j['id'] as String,
      displayName: j['displayName'] as String,
      minScore: minScore,
      keywordRules: keywords,
      regexRules: regex,
      extractRules: extract,
      validateRules: validate,
    );
  }

  int score(String upperText) {
    var s = 0;
    for (final k in keywordRules) {
      if (upperText.contains(k.text.toUpperCase())) s += k.weight;
    }
    for (final r in regexRules) {
      if (r.re.hasMatch(upperText)) s += r.weight;
    }
    return s;
  }

  Map<String, String> extract(String normalized) {
    final out = <String, String>{};
    for (final entry in extractRules.entries) {
      final v = entry.value.apply(normalized);
      if (v != null && v.trim().isNotEmpty) out[entry.key] = v.trim();
    }
    return out;
  }

  Map<String, bool> validate(Map<String, String> fields) {
    final out = <String, bool>{};
    for (final entry in validateRules.entries) {
      final v = fields[entry.key];
      if (v == null) continue;
      out[entry.key] = entry.value.hasMatch(v.trim());
    }
    return out;
  }
}

class _JsonKeywordRule {
  const _JsonKeywordRule({required this.text, required this.weight});
  final String text;
  final int weight;
}

class _JsonRegexRule {
  const _JsonRegexRule({required this.re, required this.weight});
  final RegExp re;
  final int weight;
}

class _JsonExtractRule {
  _JsonExtractRule({
    required this.re,
    required this.group,
    required this.fallbackGroup,
    required this.normalize,
  });

  final RegExp re;
  final int group;
  final int? fallbackGroup;
  final String? normalize;

  factory _JsonExtractRule.fromJson(Map<String, dynamic> j) {
    return _JsonExtractRule(
      re: _jsonRegex(j['regex'] as String),
      group: (j['group'] as num?)?.toInt() ?? 0,
      fallbackGroup: (j['fallbackGroup'] as num?)?.toInt(),
      normalize: j['normalize'] as String?,
    );
  }

  String? apply(String text) {
    final m = re.firstMatch(text);
    if (m == null) return null;
    String? v = m.group(group);
    if ((v == null || v.isEmpty) && fallbackGroup != null) {
      v = m.group(fallbackGroup!);
    }
    if (v == null) return null;
    if (normalize == 'spaces_remove') {
      v = v.replaceAll(RegExp(r'\s+'), '');
    } else if (normalize == 'spaces_collapse') {
      v = v.replaceAll(RegExp(r'\s+'), ' ');
    }
    return v;
  }
}

/// Returned from [_CropDocumentScreen]: cropped file, retake raw capture, or cancel.
class _CropScreenResult {
  const _CropScreenResult({this.croppedFile, this.retakePhoto = false});

  final File? croppedFile;
  final bool retakePhoto;
}

enum _StartFlowMode {
  twoStep,
  selfieWithDocument,
}

class _CropDocumentScreen extends StatefulWidget {
  const _CropDocumentScreen({required this.imagePath});

  final String imagePath;

  @override
  State<_CropDocumentScreen> createState() => _CropDocumentScreenState();
}

class _CropDocumentScreenState extends State<_CropDocumentScreen> {
  List<Offset>? _corners;
  List<Offset>?
  _autoCorners01; // normalized (0..1) topLeft, topRight, bottomRight, bottomLeft
  Size? _viewSize;
  bool _hasUserAdjustedCorners = false;

  static const double _handleSize = 20;

  /// Minimum inset from screen edges for the **center** of each handle so the
  /// touch target stays on-screen and drags work at extreme left/right.
  static const double _cornerCenterInset = 26;

  /// Material-like min touch target (visual handle stays smaller, centered).
  static const double _touchTarget = 48;

  double _draggableInset(double width, double height) {
    final m = math.min(width, height) / 2 - 2;
    return _cornerCenterInset.clamp(0.0, m > 0 ? m : 0.0);
  }

  void _applySafeCornerInsets(double width, double height) {
    if (_corners == null) return;
    final p = _draggableInset(width, height);
    for (var i = 0; i < 4; i++) {
      _corners![i] = Offset(
        _corners![i].dx.clamp(p, width - p),
        _corners![i].dy.clamp(p, height - p),
      );
    }
  }

  /// Order: topLeft, topRight, bottomRight, bottomLeft
  void _initCorners(double width, double height) {
    final margin = 0.1;
    if (_corners != null) return;

    // Prefer auto-detected corners if available; otherwise fall back.
    if (_autoCorners01 != null && _autoCorners01!.length == 4) {
      _corners = _autoCorners01!
          .map((p) => Offset(p.dx * width, p.dy * height))
          .toList(growable: false);
    } else {
      _corners = [
        Offset(width * margin, height * margin),
        Offset(width * (1 - margin), height * margin),
        Offset(width * (1 - margin), height * (1 - margin)),
        Offset(width * margin, height * (1 - margin)),
      ];
    }

    _applySafeCornerInsets(width, height);
  }

  @override
  void initState() {
    super.initState();
    _detectAutoCorners();
  }

  Future<void> _detectAutoCorners() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return;

      final inputImage = InputImage.fromFilePath(widget.imagePath);
      final recognizer = TextRecognizer();
      final result = await recognizer.processImage(inputImage);
      recognizer.close();

      // 1) Try OCR-based rectangle.
      final ocrAuto01 = _detectAutoCornersFromText(
        result,
        decoded.width,
        decoded.height,
      );
      // 2) If OCR is weak, try an edge-based rectangle.
      final auto01 = ocrAuto01 ?? _detectAutoCornersFromEdges(decoded);
      if (auto01 == null) return;

      if (!mounted) return;
      setState(() {
        _autoCorners01 = auto01;
        // Apply automatically unless user has already moved corners manually.
        if (!_hasUserAdjustedCorners && _viewSize != null) {
          _corners = auto01
              .map(
                (p) =>
                    Offset(p.dx * _viewSize!.width, p.dy * _viewSize!.height),
              )
              .toList(growable: false);
          _applySafeCornerInsets(_viewSize!.width, _viewSize!.height);
        }
      });
    } catch (_) {
      // Ignore: fall back to default corners.
    }
  }

  List<Offset>? _detectAutoCornersFromText(
    RecognizedText result,
    int width,
    int height,
  ) {
    // Too little OCR text means low confidence for automatic document box.
    if (result.blocks.length < 3) return null;

    double? minX, minY, maxX, maxY;
    for (final block in result.blocks) {
      final pts = block.cornerPoints;
      if (pts.isEmpty) continue;
      for (final p in pts) {
        final x = p.x.toDouble();
        final y = p.y.toDouble();
        minX = minX == null ? x : math.min(minX, x);
        minY = minY == null ? y : math.min(minY, y);
        maxX = maxX == null ? x : math.max(maxX, x);
        maxY = maxY == null ? y : math.max(maxY, y);
      }
    }

    if (minX == null ||
        minY == null ||
        maxX == null ||
        maxY == null ||
        maxX <= minX ||
        maxY <= minY) {
      return null;
    }

    // Smaller padding — tight around text keeps corners closer to the card.
    final padX = (maxX - minX) * 0.06;
    final padY = (maxY - minY) * 0.10;

    final left = (minX - padX).clamp(0.0, width.toDouble());
    final top = (minY - padY).clamp(0.0, height.toDouble());
    final right = (maxX + padX).clamp(0.0, width.toDouble());
    final bottom = (maxY + padY).clamp(0.0, height.toDouble());

    return _buildValidatedAutoRect(
      left,
      top,
      right,
      bottom,
      width.toDouble(),
      height.toDouble(),
    );
  }

  List<Offset>? _detectAutoCornersFromEdges(img.Image decoded) {
    const targetW = 640;
    final resized = decoded.width > targetW
        ? img.copyResize(decoded, width: targetW)
        : decoded;

    final gray = img.grayscale(resized);
    final w = gray.width;
    final h = gray.height;
    if (w < 20 || h < 20) return null;

    // Prefer "bright island" (ID) on darker / busy fabric backgrounds.
    final lumBox = _coarseBoxFromLuminance(gray);
    // Fallback: stricter gradient hull than before (less background bleed).
    final edgeBox = lumBox ?? _coarseBoxFromEdgeHull(gray);

    if (edgeBox == null) return null;

    var left = edgeBox.$1;
    var top = edgeBox.$2;
    var right = edgeBox.$3;
    var bottom = edgeBox.$4;

    if (right <= left || bottom <= top) return null;

    // Snap each side to a strong local edge inside a small search band.
    final refined = _refineBoxByLocalEdges(gray, left, top, right, bottom);
    left = refined.$1;
    top = refined.$2;
    right = refined.$3;
    bottom = refined.$4;

    if (right <= left || bottom <= top) return null;

    final scaleX = decoded.width / w;
    final scaleY = decoded.height / h;
    final l = (left * scaleX);
    final t = (top * scaleY);
    final r = (right * scaleX);
    final b = (bottom * scaleY);

    return _buildValidatedAutoRect(
      l,
      t,
      r,
      b,
      decoded.width.toDouble(),
      decoded.height.toDouble(),
    );
  }

  /// Bounding box of mostly-bright rows/columns (typical ID on patterned surface).
  (int, int, int, int)? _coarseBoxFromLuminance(img.Image gray) {
    final w = gray.width;
    final h = gray.height;
    final xMin = (w * 0.06).toInt();
    final xMax = (w * 0.94).toInt();
    final yMin = (h * 0.06).toInt();
    final yMax = (h * 0.94).toInt();
    if (xMax <= xMin || yMax <= yMin) return null;

    var sum = 0.0;
    var sum2 = 0.0;
    var n = 0;
    for (var y = yMin; y < yMax; y++) {
      for (var x = xMin; x < xMax; x++) {
        final v = gray.getPixel(x, y).r.toDouble();
        sum += v;
        sum2 += v * v;
        n++;
      }
    }
    if (n == 0) return null;
    final mean = sum / n;
    final var_ = (sum2 / n - mean * mean).clamp(0.0, 1e9);
    final std = math.sqrt(var_);
    final thr = mean + 0.22 * std;
    if (thr > 250) return null;

    final rowBrightFrac = List<double>.filled(h, 0);
    final colBrightFrac = List<double>.filled(w, 0);

    final rowDen = (xMax - xMin).toDouble();
    final colDen = (yMax - yMin).toDouble();

    for (var y = yMin; y < yMax; y++) {
      var bright = 0;
      for (var x = xMin; x < xMax; x++) {
        if (gray.getPixel(x, y).r.toDouble() > thr) bright++;
      }
      rowBrightFrac[y] = bright / rowDen;
    }
    for (var x = xMin; x < xMax; x++) {
      var bright = 0;
      for (var y = yMin; y < yMax; y++) {
        if (gray.getPixel(x, y).r.toDouble() > thr) bright++;
      }
      colBrightFrac[x] = bright / colDen;
    }

    const fracTh = 0.42;
    int? top;
    for (var y = yMin; y < yMax; y++) {
      if (rowBrightFrac[y] > fracTh) {
        top = y;
        break;
      }
    }
    int? bottom;
    for (var y = yMax - 1; y >= yMin; y--) {
      if (rowBrightFrac[y] > fracTh) {
        bottom = y;
        break;
      }
    }
    int? left;
    for (var x = xMin; x < xMax; x++) {
      if (colBrightFrac[x] > fracTh) {
        left = x;
        break;
      }
    }
    int? right;
    for (var x = xMax - 1; x >= xMin; x--) {
      if (colBrightFrac[x] > fracTh) {
        right = x;
        break;
      }
    }

    if (top == null || bottom == null || left == null || right == null) {
      return null;
    }
    if (right <= left || bottom <= top) return null;

    // Small margin so we don’t clip the card border.
    const m = 0.03;
    final mx = ((right - left) * m).round().clamp(2, 24);
    final my = ((bottom - top) * m).round().clamp(2, 24);
    return (
      (left - mx).clamp(0, w - 2),
      (top - my).clamp(0, h - 2),
      (right + mx).clamp(2, w - 1),
      (bottom + my).clamp(2, h - 1),
    );
  }

  (int, int, int, int)? _coarseBoxFromEdgeHull(img.Image gray) {
    final w = gray.width;
    final h = gray.height;

    final rowEnergy = List<double>.filled(h, 0);
    final colEnergy = List<double>.filled(w, 0);

    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final c = gray.getPixel(x, y).r.toDouble();
        final rx = gray.getPixel(x + 1, y).r.toDouble();
        final by = gray.getPixel(x, y + 1).r.toDouble();
        final e = (rx - c).abs() + (by - c).abs();
        rowEnergy[y] += e;
        colEnergy[x] += e;
      }
    }

    final rowMax = rowEnergy.reduce(math.max);
    final colMax = colEnergy.reduce(math.max);
    if (rowMax <= 0 || colMax <= 0) return null;

    // Higher threshold = ignore weak fabric texture; hull shrinks toward subject.
    final rowThresh = rowMax * 0.52;
    final colThresh = colMax * 0.52;

    var top = 0;
    while (top < h && rowEnergy[top] < rowThresh) {
      top++;
    }
    var bottom = h - 1;
    while (bottom >= 0 && rowEnergy[bottom] < rowThresh) {
      bottom--;
    }
    var left = 0;
    while (left < w && colEnergy[left] < colThresh) {
      left++;
    }
    var right = w - 1;
    while (right >= 0 && colEnergy[right] < colThresh) {
      right--;
    }

    if (right <= left || bottom <= top) return null;
    return (left, top, right, bottom);
  }

  /// Move each edge to the strongest 1D edge response within a band around the coarse edge.
  (int, int, int, int) _refineBoxByLocalEdges(
    img.Image gray,
    int left,
    int top,
    int right,
    int bottom,
  ) {
    final w = gray.width;
    final h = gray.height;

    final x0 = (w * 0.10).round().clamp(1, w - 3);
    final x1 = (w * 0.90).round().clamp(2, w - 2);
    final y0 = (h * 0.10).round().clamp(1, h - 3);
    final y1 = (h * 0.90).round().clamp(2, h - 2);

    final bandY = (0.06 * h).round().clamp(4, 48);
    final bandX = (0.06 * w).round().clamp(4, 48);

    double horizStrength(int y) {
      if (y <= 0 || y >= h - 1) return 0;
      var s = 0.0;
      for (var x = x0; x < x1; x++) {
        s += (gray.getPixel(x, y).r - gray.getPixel(x, y - 1).r)
            .abs()
            .toDouble();
      }
      return s;
    }

    double vertStrength(int x) {
      if (x <= 0 || x >= w - 1) return 0;
      var s = 0.0;
      for (var y = y0; y < y1; y++) {
        s += (gray.getPixel(x, y).r - gray.getPixel(x - 1, y).r)
            .abs()
            .toDouble();
      }
      return s;
    }

    // Top: search downward from (coarse top - band) to (coarse top + band).
    var bestTop = top;
    var bestTopScore = horizStrength(top.clamp(1, h - 2));
    final t0 = (top - bandY).clamp(1, h - 2);
    final t1 = (top + bandY).clamp(1, h - 2);
    for (var y = t0; y <= t1; y++) {
      final s = horizStrength(y);
      if (s > bestTopScore) {
        bestTopScore = s;
        bestTop = y;
      }
    }

    var bestBottom = bottom;
    var bestBottomScore = horizStrength(bottom.clamp(1, h - 2));
    final b0 = (bottom - bandY).clamp(1, h - 2);
    final b1 = (bottom + bandY).clamp(1, h - 2);
    for (var y = b0; y <= b1; y++) {
      final s = horizStrength(y);
      if (s > bestBottomScore) {
        bestBottomScore = s;
        bestBottom = y;
      }
    }

    var bestLeft = left;
    var bestLeftScore = vertStrength(left.clamp(1, w - 2));
    final l0 = (left - bandX).clamp(1, w - 2);
    final l1 = (left + bandX).clamp(1, w - 2);
    for (var x = l0; x <= l1; x++) {
      final s = vertStrength(x);
      if (s > bestLeftScore) {
        bestLeftScore = s;
        bestLeft = x;
      }
    }

    var bestRight = right;
    var bestRightScore = vertStrength(right.clamp(1, w - 2));
    final r0 = (right - bandX).clamp(1, w - 2);
    final r1 = (right + bandX).clamp(1, w - 2);
    for (var x = r0; x <= r1; x++) {
      final s = vertStrength(x);
      if (s > bestRightScore) {
        bestRightScore = s;
        bestRight = x;
      }
    }

    if (bestRight <= bestLeft || bestBottom <= bestTop) {
      return (left, top, right, bottom);
    }
    return (bestLeft, bestTop, bestRight, bestBottom);
  }

  List<Offset>? _buildValidatedAutoRect(
    double left,
    double top,
    double right,
    double bottom,
    double w,
    double h,
  ) {
    final boxW = right - left;
    final boxH = bottom - top;
    if (boxW <= 0 || boxH <= 0) return null;

    final areaRatio = (boxW * boxH) / (w * h);
    final aspect = boxW / boxH;
    if (areaRatio < 0.10 || areaRatio > 0.92) return null;
    if (aspect < 0.7 || aspect > 2.8) return null;

    final centerX = (left + right) / 2;
    final centerY = (top + bottom) / 2;
    final nx = (centerX - w / 2).abs() / (w / 2);
    final ny = (centerY - h / 2).abs() / (h / 2);
    if (nx > 0.75 || ny > 0.75) return null;

    return <Offset>[
      Offset((left / w).clamp(0.0, 1.0), (top / h).clamp(0.0, 1.0)),
      Offset((right / w).clamp(0.0, 1.0), (top / h).clamp(0.0, 1.0)),
      Offset((right / w).clamp(0.0, 1.0), (bottom / h).clamp(0.0, 1.0)),
      Offset((left / w).clamp(0.0, 1.0), (bottom / h).clamp(0.0, 1.0)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop<_CropScreenResult?>(null),
        ),
        title: const Text('Match card corners'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context)
                .pop(const _CropScreenResult(retakePhoto: true)),
            child: const Text('Retake photo'),
          ),
          TextButton(
            onPressed: () async {
              if (_viewSize == null || _corners == null) {
                Navigator.of(context).pop<_CropScreenResult?>(null);
                return;
              }
              final cropped = await _cropAndEnhance();
              if (!context.mounted) return;
              if (cropped == null) {
                Navigator.of(context).pop<_CropScreenResult?>(null);
                return;
              }
              Navigator.of(context)
                  .pop(_CropScreenResult(croppedFile: cropped));
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
                // Keep handles grabbable when auto-detect snaps to image edges.
                _applySafeCornerInsets(width, height);
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
                    _buildHandle(corners[0], (delta) => _moveCorner(0, delta)),
                    _buildHandle(corners[1], (delta) => _moveCorner(1, delta)),
                    _buildHandle(corners[2], (delta) => _moveCorner(2, delta)),
                    _buildHandle(corners[3], (delta) => _moveCorner(3, delta)),
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
    final p = _draggableInset(size.width, size.height);
    setState(() {
      _hasUserAdjustedCorners = true;
      final c = _corners![index];
      _corners![index] = Offset(
        (c.dx + delta.dx).clamp(p, size.width - p),
        (c.dy + delta.dy).clamp(p, size.height - p),
      );
    });
  }

  /// Detects tilt angle (degrees) from text block orientation in the cropped image.
  /// Uses a small thumbnail so ML Kit is fast (full-size PNG was very slow).
  Future<double> _detectTiltAngle(img.Image image) async {
    final dir = await getTemporaryDirectory();
    final tempPath =
        '${dir.path}/_tilt_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final tempFile = File(tempPath);
    try {
      var probe = image;
      if (image.width > 400) {
        probe = img.copyResize(image, width: 400);
      }
      await tempFile.writeAsBytes(img.encodeJpg(probe, quality: 82));
      final inputImage = InputImage.fromFilePath(tempPath);
      final recognizer = TextRecognizer();
      final result = await recognizer.processImage(inputImage);
      recognizer.close();

      double sumDeg = 0;
      int count = 0;
      for (final block in result.blocks) {
        final pts = block.cornerPoints;
        if (pts.length >= 2) {
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
      left: position.dx - _touchTarget / 2,
      top: position.dy - _touchTarget / 2,
      child: GestureDetector(
        dragStartBehavior: DragStartBehavior.down,
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          onDrag(details.delta);
        },
        child: SizedBox(
          width: _touchTarget,
          height: _touchTarget,
          child: Center(
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

    final srcQuad = corners
        .map((o) => Offset(o.dx * scaleX, o.dy * scaleY))
        .toList();

    final w1 = _dist(srcQuad[0], srcQuad[1]);
    final w2 = _dist(srcQuad[3], srcQuad[2]);
    final h1 = _dist(srcQuad[0], srcQuad[3]);
    final h2 = _dist(srcQuad[1], srcQuad[2]);
    // Full-resolution warp is O(outW*outH) in Dart — cap for sub‑second UX on phones.
    const maxSide = 640;
    var outW = (math.max(w1, w2)).round().clamp(1, original.width);
    var outH = (math.max(h1, h2)).round().clamp(1, original.height);
    if (outW > maxSide || outH > maxSide) {
      if (outW >= outH) {
        outH = (outH * maxSide / outW).round().clamp(1, original.height);
        outW = maxSide;
      } else {
        outW = (outW * maxSide / outH).round().clamp(1, original.width);
        outH = maxSide;
      }
    }

    img.Image? work = _perspectiveWarp(original, srcQuad, outW, outH);
    if (work == null) return null;

    // Light tilt fix only if needed; OCR runs on small thumbnail inside _detectTiltAngle.
    final tiltAngle = await _detectTiltAngle(work);
    if (tiltAngle.abs() > 1.2) {
      work = img.copyRotate(work, angle: -tiltAngle);
    }

    final gray = img.grayscale(work);
    final enhanced = img.adjustColor(gray, contrast: 1.2);

    final dir = await getTemporaryDirectory();
    final outPath =
        '${dir.path}/scan_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final outFile = File(outPath);
    await outFile.writeAsBytes(img.encodeJpg(enhanced, quality: 90));
    return outFile;
  }

  double _dist(Offset a, Offset b) {
    return math.sqrt(
      (a.dx - b.dx) * (a.dx - b.dx) + (a.dy - b.dy) * (a.dy - b.dy),
    );
  }

  /// Warps source image so quad (topLeft, topRight, bottomRight, bottomLeft) becomes a straight rectangle.
  img.Image? _perspectiveWarp(
    img.Image src,
    List<Offset> quad,
    int outW,
    int outH,
  ) {
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
      for (var j = 0; j <= n; j++) {
        a[col][j] /= pivot;
      }
      for (var row = 0; row < n; row++) {
        if (row == col) continue;
        final f = a[row][col];
        for (var j = 0; j <= n; j++) {
          a[row][j] -= f * a[col][j];
        }
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
    final r =
        (p00.r * (1 - fx) * (1 - fy) +
                p10.r * fx * (1 - fy) +
                p01.r * (1 - fx) * fy +
                p11.r * fx * fy)
            .round()
            .clamp(0, 255);
    final g =
        (p00.g * (1 - fx) * (1 - fy) +
                p10.g * fx * (1 - fy) +
                p01.g * (1 - fx) * fy +
                p11.g * fx * fy)
            .round()
            .clamp(0, 255);
    final b =
        (p00.b * (1 - fx) * (1 - fy) +
                p10.b * fx * (1 - fy) +
                p01.b * (1 - fx) * fy +
                p11.b * fx * fy)
            .round()
            .clamp(0, 255);
    final a =
        (p00.a * (1 - fx) * (1 - fy) +
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
    final overlayPaint = Paint()..color = Colors.black.withValues(alpha: 0.5);
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
  final TextRecognizer _textRecognizer = TextRecognizer();
  final FaceMatchService _faceMatchService = FaceMatchService();
  final TextEditingController _documentNumberController =
      TextEditingController();

  String _recognizedText = '';
  bool _isProcessing = false;
  String _processingMessage = '';
  XFile? _imageFile;
  XFile? _selfieFile;
  // Only used in "Selfie + ID" flow: the original photo that contains both
  // the user's face and the document. `_selfieFile` is then a cropped face
  // preview for the UI.
  XFile? _selfieWithDocFile;
  String? _detectedDocumentNumber;
  double? _matchPercent;
  bool? _isDocumentNumberMatch;

  double? _faceMatchPercent;
  bool? _isFaceMatchPass;
  String? _faceMatchError;
  // Kept for potential future UI/debug use.
  bool _faceUsedEmbeddingModel = false;

  _StartFlowMode? _flowMode;

  Map<String, String> _extractedFields = const {};
  String _detectedTemplateText = 'Unknown';
  _JsonTemplateEngine? _jsonTemplates;
  bool _jsonLoading = false;
  String? _pendingOcrForJson;

  @override
  void initState() {
    super.initState();
    _loadJsonTemplates();
  }

  @override
  void dispose() {
    _documentNumberController.dispose();
    _textRecognizer.close();
    _faceMatchService.dispose();
    super.dispose();
  }

  Future<void> _loadJsonTemplates() async {
    if (_jsonTemplates != null || _jsonLoading) return;
    _jsonLoading = true;
    try {
      final engine = await _JsonTemplateEngine.loadFromAssets();
      if (!mounted) return;
      setState(() => _jsonTemplates = engine);
      final pending = _pendingOcrForJson;
      if (pending != null) {
        _pendingOcrForJson = null;
        _runTemplatePipeline(pending);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _detectedTemplateText = 'Template load failed');
    } finally {
      _jsonLoading = false;
    }
  }

  String? _pickDocumentNumberFromFields(Map<String, String> fields) {
    const keysByPriority = <String>[
      'PAN',
      'Aadhaar',
      'DL No',
      'Licence No',
      'Passport No',
      'Document No',
    ];
    for (final k in keysByPriority) {
      final v = fields[k];
      if (v != null && v.trim().isNotEmpty) {
        return v.trim();
      }
    }
    return null;
  }

  void _updateDocumentNumberMatch() {
    final expected = _documentNumberController.text.trim();
    final detected = _detectedDocumentNumber?.trim() ?? '';

    if (expected.isEmpty || detected.isEmpty) {
    setState(() {
        _matchPercent = null;
        _isDocumentNumberMatch = null;
      });
      return;
    }

    final similarity = _calculateSimilarity(
      expected.toLowerCase(),
      detected.toLowerCase(),
    );

    setState(() {
      _matchPercent = similarity * 100;
      _isDocumentNumberMatch = similarity >= 0.8;
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
    final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));

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

  Future<String?> _captureDocumentPhoto() async {
    return Navigator.of(context).push<String?>(
      MaterialPageRoute(builder: (_) => const _AutoCaptureCameraScreen()),
    );
  }

  Future<File?> _cropDocumentPhoto(String rawPath) async {
    while (mounted) {
      final result = await Navigator.of(context).push<_CropScreenResult?>(
        MaterialPageRoute(
          builder: (_) => _CropDocumentScreen(imagePath: rawPath),
        ),
      );
      if (!mounted) return null;
      if (result == null) return null;
      if (result.retakePhoto) {
        final again = await _captureDocumentPhoto();
        if (!mounted) return null;
        if (again == null) return null;
        rawPath = again;
        continue;
      }
      return result.croppedFile;
    }
    return null;
  }

  Future<String?> _captureSelfiePhoto() async {
    return Navigator.of(context).push<String?>(
      MaterialPageRoute(builder: (_) => const _SelfieCaptureScreen()),
    );
  }

  Future<void> _processCapturedImages({
    required String idPath,
    required String selfiePath,
  }) async {
    setState(() {
      _isProcessing = true;
      _processingMessage = 'Running OCR and face match…';
      _imageFile = XFile(idPath);
      _selfieFile = XFile(selfiePath);
    });

    try {
      final results = await Future.wait<Object?>([
        _textRecognizer.processImage(InputImage.fromFilePath(idPath)),
        _faceMatchService.compare(
          idImagePath: idPath,
          selfieImagePath: selfiePath,
        ),
      ]);

      if (!mounted) return;

      final recognizedText = results[0] as RecognizedText;
      final faceResult = results[1] as FaceMatchResult;

      setState(() {
        _recognizedText = recognizedText.text;
        _isProcessing = false;
        _processingMessage = '';
        _faceMatchPercent = faceResult.matchPercent;
        _isFaceMatchPass = faceResult.pass;
        _faceMatchError = faceResult.error;
        _faceUsedEmbeddingModel = faceResult.usedEmbeddingModel;
      });
      _runTemplatePipeline(recognizedText.text);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _processingMessage = '';
        _recognizedText = 'Error: $e';
      });
    }
  }

  Future<void> _scanDocument() async {
    try {
      _flowMode = _StartFlowMode.twoStep;
      final rawPath = await _captureDocumentPhoto();
      if (!mounted || rawPath == null) return;

      final croppedFile = await _cropDocumentPhoto(rawPath);
      if (!mounted || croppedFile == null) return;

      final selfiePath = await _captureSelfiePhoto();
      if (!mounted || selfiePath == null) return;

      setState(() {
        _recognizedText = '';
        _detectedDocumentNumber = null;
        _matchPercent = null;
        _isDocumentNumberMatch = null;
        _faceMatchPercent = null;
        _isFaceMatchPass = null;
        _faceMatchError = null;
        _faceUsedEmbeddingModel = false;
      });

      await _processCapturedImages(
        idPath: croppedFile.path,
        selfiePath: selfiePath,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _processingMessage = '';
        _recognizedText = 'Error: $e';
      });
    }
  }

  Future<void> _scanSelfieWithDocument() async {
    try {
      _flowMode = _StartFlowMode.selfieWithDocument;

      final combinedPath = await Navigator.of(context).push<String?>(
        MaterialPageRoute(builder: (_) => const _SelfieWithDocumentCaptureScreen()),
      );
      if (!mounted || combinedPath == null) return;

      // Auto-crop ONLY the document out of the combined selfie+doc photo.
      final croppedDoc = await _autoCropDocumentFromPhoto(combinedPath);
      if (!mounted || croppedDoc == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not detect the document automatically. Please retake with the full card visible and closer to the camera.',
            ),
          ),
        );
        return;
      }

      setState(() {
        _recognizedText = '';
        _detectedDocumentNumber = null;
        _matchPercent = null;
        _isDocumentNumberMatch = null;
        _faceMatchPercent = null;
        _isFaceMatchPass = null;
        _faceMatchError = null;
        _faceUsedEmbeddingModel = false;
      });

      await _processSelfieWithDocument(
        combinedPath: combinedPath,
        croppedDocPath: croppedDoc.path,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _processingMessage = '';
        _recognizedText = 'Error: $e';
      });
    }
  }

  Future<File?> _autoCropDocumentFromPhoto(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      // 1) Prefer OCR-text-based detection (works well when card text is readable).
      (int, int, int, int)? rect;
      try {
        final rt =
            await _textRecognizer.processImage(InputImage.fromFilePath(imagePath));
        rect = _docRectFromOcrBlocks(rt, decoded.width, decoded.height);
      } catch (_) {
        rect = null;
      }

      // 2) Fallback to edge-based heuristic.
      rect ??= _autoDetectDocumentRect(decoded);
      if (rect == null) return null;
      final (left, top, right, bottom) = rect;

      final cropped = img.copyCrop(
        decoded,
        x: left,
        y: top,
        width: (right - left).clamp(1, decoded.width),
        height: (bottom - top).clamp(1, decoded.height),
      );

      final gray = img.grayscale(cropped);
      final enhanced = img.adjustColor(gray, contrast: 1.2);

      final dir = await getTemporaryDirectory();
      final outPath =
          '${dir.path}/doc_auto_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final outFile = File(outPath);
      await outFile.writeAsBytes(img.encodeJpg(enhanced, quality: 90));
      return outFile;
    } catch (_) {
      return null;
    }
  }

  (int, int, int, int)? _docRectFromOcrBlocks(
    RecognizedText rt,
    int imgW,
    int imgH,
  ) {
    final blocks = rt.blocks;
    if (blocks.isEmpty) return null;

    // Score blocks that are more likely to belong to the ID card region.
    final scored = <TextBlock, double>{};
    for (final b in blocks) {
      final bb = b.boundingBox;
      final area = (bb.width * bb.height).abs();
      if (area < 250) continue;
      final cx = bb.left + bb.width / 2;
      final cy = bb.top + bb.height / 2;
      final nx = cx / imgW;
      final ny = cy / imgH;

      // In selfie+ID photo, card is usually in lower-right; bias toward that,
      // but still allow other positions.
      final bias = (0.6 * nx + 0.4 * ny);
      scored[b] = area * (0.6 + bias);
    }
    if (scored.isEmpty) return null;

    // Use top-N blocks to form a rectangle.
    final topBlocks = scored.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final takeN = math.min(16, topBlocks.length);

    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;

    for (var i = 0; i < takeN; i++) {
      final b = topBlocks[i].key;
      final pts = b.cornerPoints;
      if (pts.isNotEmpty) {
        for (final p in pts) {
          minX = math.min(minX, p.x.toDouble());
          minY = math.min(minY, p.y.toDouble());
          maxX = math.max(maxX, p.x.toDouble());
          maxY = math.max(maxY, p.y.toDouble());
        }
      } else {
        final bb = b.boundingBox;
        minX = math.min(minX, bb.left);
        minY = math.min(minY, bb.top);
        maxX = math.max(maxX, bb.right);
        maxY = math.max(maxY, bb.bottom);
      }
    }

    if (!minX.isFinite ||
        !minY.isFinite ||
        !maxX.isFinite ||
        !maxY.isFinite) {
      return null;
    }

    // Expand around text to approximate full card bounds.
    final padX = (0.35 * (maxX - minX)).clamp(24.0, imgW.toDouble());
    final padY = (0.55 * (maxY - minY)).clamp(24.0, imgH.toDouble());

    var left = (minX - padX).floor();
    var right = (maxX + padX).ceil();
    var top = (minY - padY).floor();
    var bottom = (maxY + padY).ceil();

    left = left.clamp(0, imgW - 2);
    right = right.clamp(left + 1, imgW - 1);
    top = top.clamp(0, imgH - 2);
    bottom = bottom.clamp(top + 1, imgH - 1);

    final boxW = (right - left).toDouble();
    final boxH = (bottom - top).toDouble();
    final areaRatio = (boxW * boxH) / (imgW * imgH);
    final aspect = boxW / boxH;

    // Be more permissive here because card can be smaller in-frame.
    if (areaRatio < 0.04 || areaRatio > 0.92) return null;
    if (aspect < 0.6 || aspect > 3.2) return null;

    return (left, top, right, bottom);
  }

  /// Heuristic auto-detection of an ID-card-like rectangle in a photo.
  ///
  /// Returns (left, top, right, bottom) in *original* image pixels.
  /// Works best when the document occupies a meaningful portion of the frame.
  (int, int, int, int)? _autoDetectDocumentRect(img.Image original) {
    // Downscale for speed and to smooth noise.
    final targetW = 360;
    final scale = targetW / original.width;
    final small = img.copyResize(
      original,
      width: targetW,
      height: (original.height * scale).round().clamp(1, 5000),
      interpolation: img.Interpolation.linear,
    );

    final w = small.width;
    final h = small.height;

    // Compute simple edge magnitude per pixel using grayscale gradients.
    final gray = img.grayscale(small);
    final rowEdge = List<double>.filled(h, 0);
    final colEdge = List<double>.filled(w, 0);

    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final c = gray.getPixel(x, y).r.toDouble();
        final dx = (gray.getPixel(x + 1, y).r.toDouble() -
                gray.getPixel(x - 1, y).r.toDouble())
            .abs();
        final dy = (gray.getPixel(x, y + 1).r.toDouble() -
                gray.getPixel(x, y - 1).r.toDouble())
            .abs();
        // A touch of center weighting reduces picking frame borders.
        final cx = (x - w / 2).abs() / (w / 2);
        final cy = (y - h / 2).abs() / (h / 2);
        final weight = 1.0 - (0.25 * (cx + cy)).clamp(0.0, 0.5);
        final e = (dx + dy) * weight + (c * 0); // keep as double, no-op term

        rowEdge[y] += e;
        colEdge[x] += e;
      }
    }

    int argMax(List<double> v) {
      var bestI = 0;
      var best = -1.0;
      for (var i = 0; i < v.length; i++) {
        if (v[i] > best) {
          best = v[i];
          bestI = i;
        }
      }
      return bestI;
    }

    // Initial edges are max projections.
    var top = argMax(rowEdge.sublist(0, (h * 0.6).round().clamp(2, h)));
    var bottom = argMax(rowEdge
            .sublist((h * 0.4).round().clamp(0, h - 2), h - 1)) +
        (h * 0.4).round().clamp(0, h - 2);
    var left = argMax(colEdge.sublist(0, (w * 0.6).round().clamp(2, w)));
    var right = argMax(colEdge
            .sublist((w * 0.4).round().clamp(0, w - 2), w - 1)) +
        (w * 0.4).round().clamp(0, w - 2);

    // Expand a little to include borders.
    final padX = (0.03 * w).round();
    final padY = (0.03 * h).round();
    left = (left - padX).clamp(0, w - 2);
    right = (right + padX).clamp(left + 1, w - 1);
    top = (top - padY).clamp(0, h - 2);
    bottom = (bottom + padY).clamp(top + 1, h - 1);

    final boxW = (right - left).toDouble();
    final boxH = (bottom - top).toDouble();
    if (boxW <= 0 || boxH <= 0) return null;

    final areaRatio = (boxW * boxH) / (w * h);
    final aspect = boxW / boxH;
    // Typical ID card aspect ~1.4–1.7; allow wider range for perspective.
    if (areaRatio < 0.08 || areaRatio > 0.92) return null;
    if (aspect < 0.6 || aspect > 3.2) return null;

    // Scale back to original coordinates.
    final inv = 1 / scale;
    final oLeft = (left * inv).round().clamp(0, original.width - 2);
    final oRight = (right * inv).round().clamp(oLeft + 1, original.width - 1);
    final oTop = (top * inv).round().clamp(0, original.height - 2);
    final oBottom =
        (bottom * inv).round().clamp(oTop + 1, original.height - 1);

    return (oLeft, oTop, oRight, oBottom);
  }

  Future<void> _processSelfieWithDocument({
    required String combinedPath,
    required String croppedDocPath,
  }) async {
    final selfiePreview = await _autoCropSelfieFacePreview(combinedPath);

    setState(() {
      _isProcessing = true;
      _processingMessage = 'Running OCR and face match…';
      _imageFile = XFile(croppedDocPath);
      _selfieWithDocFile = XFile(combinedPath);
      _selfieFile = selfiePreview != null ? XFile(selfiePreview.path) : null;
    });

    try {
      final results = await Future.wait<Object?>([
        _textRecognizer.processImage(InputImage.fromFilePath(croppedDocPath)),
        _faceMatchService.compareSelfieWithDocument(
          combinedSelfieWithDocPath: combinedPath,
          croppedDocumentPath: croppedDocPath,
        ),
      ]);

      if (!mounted) return;

      final recognizedText = results[0] as RecognizedText;
      final faceResult = results[1] as FaceMatchResult;

      setState(() {
        _recognizedText = recognizedText.text;
        _isProcessing = false;
        _processingMessage = '';
        _faceMatchPercent = faceResult.matchPercent;
        _isFaceMatchPass = faceResult.pass;
        _faceMatchError = faceResult.error;
        _faceUsedEmbeddingModel = faceResult.usedEmbeddingModel;
      });
      _runTemplatePipeline(recognizedText.text);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _processingMessage = '';
        _recognizedText = 'Error: $e';
      });
    }
  }

  Future<File?> _autoCropSelfieFacePreview(String combinedPath) async {
    try {
      final detector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          minFaceSize: 0.12,
        ),
      );
      final faces = await detector.processImage(
        InputImage.fromFilePath(combinedPath),
      );
      detector.close();
      if (faces.isEmpty) return null;

      Face best = faces.first;
      var bestArea = 0.0;
      for (final f in faces) {
        final a = f.boundingBox.width * f.boundingBox.height;
        if (a > bestArea) {
          bestArea = a;
          best = f;
        }
      }

      final bytes = await File(combinedPath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      final box = best.boundingBox;
      final padX = box.width * 0.25;
      final padY = box.height * 0.30;
      var left = (box.left - padX).floor();
      var top = (box.top - padY).floor();
      var right = (box.right + padX).ceil();
      var bottom = (box.bottom + padY).ceil();

      left = left.clamp(0, decoded.width - 1);
      top = top.clamp(0, decoded.height - 1);
      right = right.clamp(left + 1, decoded.width);
      bottom = bottom.clamp(top + 1, decoded.height);

      final crop = img.copyCrop(
        decoded,
        x: left,
        y: top,
        width: right - left,
        height: bottom - top,
      );

      final resized = img.copyResize(crop, width: 320);
      final dir = await getTemporaryDirectory();
      final outPath =
          '${dir.path}/selfie_face_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final outFile = File(outPath);
      await outFile.writeAsBytes(img.encodeJpg(resized, quality: 90));
      return outFile;
    } catch (_) {
      return null;
    }
  }

  Future<void> _changeDocument() async {
    if (_isProcessing) return;

    if (_flowMode == _StartFlowMode.selfieWithDocument) {
      final combined = _selfieWithDocFile?.path;
      if (combined == null) {
        await _scanSelfieWithDocument();
        return;
      }
      final croppedDoc = await _autoCropDocumentFromPhoto(combined);
      if (!mounted || croppedDoc == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not detect the document automatically. Please retake the photo.',
            ),
          ),
        );
        return;
      }
      await _processSelfieWithDocument(
        combinedPath: combined,
        croppedDocPath: croppedDoc.path,
      );
      return;
    }

    final rawPath = await _captureDocumentPhoto();
    if (!mounted || rawPath == null) return;

    final croppedFile = await _cropDocumentPhoto(rawPath);
    if (!mounted || croppedFile == null) return;

    final selfiePath = _selfieFile?.path;
    if (selfiePath != null) {
      await _processCapturedImages(
        idPath: croppedFile.path,
        selfiePath: selfiePath,
      );
    } else {
      setState(() => _imageFile = XFile(croppedFile.path));
    }
  }

  Future<void> _changeSelfie() async {
    if (_isProcessing) return;

    if (_flowMode == _StartFlowMode.selfieWithDocument) {
      await _scanSelfieWithDocument();
      return;
    }

    final idPath = _imageFile?.path;
    if (idPath == null) {
      await _scanDocument();
      return;
    }

    final selfiePath = await _captureSelfiePhoto();
    if (!mounted || selfiePath == null) return;

    await _processCapturedImages(idPath: idPath, selfiePath: selfiePath);
  }

  void _runTemplatePipeline(String ocrText) {
    final engine = _jsonTemplates;
    if (engine == null) {
      _pendingOcrForJson = ocrText;
      if (_detectedTemplateText != 'Loading…') {
        setState(() => _detectedTemplateText = 'Loading…');
      }
      _loadJsonTemplates();
      return;
    }

    final result = engine.detect(ocrText);
    setState(() {
      _detectedTemplateText = result.displayName;
      _extractedFields = result.fields;
      _detectedDocumentNumber = _pickDocumentNumberFromFields(result.fields);
    });
    _updateDocumentNumberMatch();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OCR Document Scanner')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.document_scanner),
                    label: const Text('Scan ID'),
                    onPressed: _isProcessing ? null : _scanDocument,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.face),
                    label: const Text('Selfie + ID'),
                    onPressed: _isProcessing ? null : _scanSelfieWithDocument,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_isProcessing) ...[
              const CircularProgressIndicator(),
              if (_processingMessage.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(_processingMessage),
              ],
            ],
            if ((_imageFile != null || _selfieFile != null) && !_isProcessing) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_imageFile != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _changeDocument,
                        icon: const Icon(Icons.badge_outlined),
                        label: const Text('Change document'),
                      ),
                    ),
                  if (_imageFile != null && _selfieFile != null)
                    const SizedBox(width: 8),
                  if (_selfieFile != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _changeSelfie,
                        icon: const Icon(Icons.face_retouching_natural),
                        label: const Text('Change selfie'),
                      ),
                    ),
                ],
              ),
            ],
            if (_imageFile != null && !_isProcessing) ...[
              const SizedBox(height: 12),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Document',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(height: 160, child: Image.file(File(_imageFile!.path))),
            ],
            if (_selfieFile != null && !_isProcessing) ...[
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Selfie',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(height: 120, child: Image.file(File(_selfieFile!.path))),
            ],
            const SizedBox(height: 16),
            if (_recognizedText.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Detected: $_detectedTemplateText',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            if (_extractedFields.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _extractedFields.entries.map((e) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: Text('${e.key}: ${e.value}')),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _documentNumberController,
              decoration: const InputDecoration(
                labelText: 'Enter document number',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _updateDocumentNumberMatch(),
            ),
            const SizedBox(height: 12),
            if (_detectedDocumentNumber != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Detected document number: $_detectedDocumentNumber',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              )
            else if (_recognizedText.isNotEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('No document number found in extracted fields.'),
              ),
            const SizedBox(height: 8),
            if (_matchPercent != null && _isDocumentNumberMatch != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Document number match: ${_isDocumentNumberMatch! ? 'True' : 'False'} '
                  '(${_matchPercent!.toStringAsFixed(1)}%)',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _isDocumentNumberMatch! ? Colors.green : Colors.red,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (_faceMatchError != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _faceMatchError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              )
            else if (_faceMatchPercent != null && _isFaceMatchPass != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Face match: ${_faceMatchPercent!.toStringAsFixed(1)}% '
                      '(${_isFaceMatchPass! ? 'Match' : 'No match'})',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _isFaceMatchPass! ? Colors.green : Colors.red,
                      ),
                    ),
                    Text(
                      _faceUsedEmbeddingModel
                          ? 'Model: MobileFaceNet'
                          : 'Model: Not loaded',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            const Text(
              'Extracted text from document',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SelectableText(
              _recognizedText.isEmpty
                  ? 'Captured text will appear here.'
                  : _recognizedText,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    ),
    );
  }
}

class _SelfieCaptureScreen extends StatefulWidget {
  const _SelfieCaptureScreen();

  @override
  State<_SelfieCaptureScreen> createState() => _SelfieCaptureScreenState();
}

/// Front-camera capture where user holds the ID next to their face.
/// Returns a single image path containing both face + document.
class _SelfieWithDocumentCaptureScreen extends StatefulWidget {
  const _SelfieWithDocumentCaptureScreen();

  @override
  State<_SelfieWithDocumentCaptureScreen> createState() =>
      _SelfieWithDocumentCaptureScreenState();
}

class _SelfieWithDocumentCaptureScreenState
    extends State<_SelfieWithDocumentCaptureScreen> {
  CameraController? _controller;
  bool _isInitializing = true;
  bool _isCapturing = false;
  String? _previewPath;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        front,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _isInitializing = false;
      });
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pop<String?>(null);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);
    try {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      final file = await c.takePicture();
      if (!mounted) return;
      setState(() {
        _previewPath = file.path;
        _isCapturing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isCapturing = false);
    }
  }

  void _retake() {
    setState(() => _previewPath = null);
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final preview = _previewPath;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop<String?>(null),
        ),
        title: Text(preview == null ? 'Selfie with ID' : 'Review'),
      ),
      body: _isInitializing || c == null
          ? const Center(child: CircularProgressIndicator())
          : preview != null
              ? Column(
                  children: [
                    Expanded(
                      child: Image.file(File(preview), fit: BoxFit.contain),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
        child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
                          FilledButton(
                            onPressed: () => Navigator.of(context).pop(preview),
                            child: const Text('Use this photo'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _retake,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retake'),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : Stack(
                  children: [
                    Positioned.fill(child: CameraPreview(c)),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _SelfieWithDocumentOverlayPainter(
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 24,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              'Hold your ID next to your face. Make sure the card text is readable and avoid glare.',
                              style: TextStyle(color: Colors.white),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _isCapturing ? null : _capture,
                            icon: const Icon(Icons.camera_alt),
                            label: Text(_isCapturing ? 'Capturing…' : 'Capture'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _SelfieWithDocumentOverlayPainter extends CustomPainter {
  _SelfieWithDocumentOverlayPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // Face guide (oval) on left side.
    final faceRect = Rect.fromCenter(
      center: Offset(size.width * 0.33, size.height * 0.42),
      width: size.width * 0.45,
      height: size.height * 0.38,
    );
    canvas.drawOval(faceRect, paint);

    // Document guide (rounded rect) on right-lower side.
    final docRect = Rect.fromCenter(
      center: Offset(size.width * 0.72, size.height * 0.62),
      width: size.width * 0.48,
      height: size.height * 0.26,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(docRect, const Radius.circular(14)),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _SelfieWithDocumentOverlayPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _SelfieCaptureScreenState extends State<_SelfieCaptureScreen> {
  CameraController? _controller;
  bool _isInitializing = true;
  bool _isCapturing = false;
  String? _previewPath;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _isInitializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop<String?>(null);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);
    try {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      final file = await c.takePicture();
      if (!mounted) return;
      setState(() {
        _previewPath = file.path;
        _isCapturing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isCapturing = false);
    }
  }

  void _retake() {
    setState(() => _previewPath = null);
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final preview = _previewPath;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop<String?>(null),
        ),
        title: Text(preview == null ? 'Take selfie' : 'Review selfie'),
      ),
      body: _isInitializing || c == null
          ? const Center(child: CircularProgressIndicator())
          : preview != null
          ? Column(
              children: [
                Expanded(
                  child: Image.file(File(preview), fit: BoxFit.contain),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(preview),
                        child: const Text('Use this selfie'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _retake,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retake'),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : Stack(
              children: [
                Positioned.fill(child: CameraPreview(c)),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'Look at the camera. Only your face should be visible.',
                          style: TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _isCapturing ? null : _capture,
                        icon: const Icon(Icons.face),
                        label: Text(
                          _isCapturing ? 'Capturing…' : 'Capture selfie',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _AutoCaptureCameraScreen extends StatefulWidget {
  const _AutoCaptureCameraScreen();

  @override
  State<_AutoCaptureCameraScreen> createState() =>
      _AutoCaptureCameraScreenState();
}

class _AutoCaptureCameraScreenState extends State<_AutoCaptureCameraScreen> {
  CameraController? _controller;
  bool _isInitializing = true;
  bool _isCapturing = false;
  String? _previewPath;

  // Stability/blur checks
  List<int>? _prevLuma; // small grayscale sample
  int _stableFrames = 0;

  static const int _sampleW = 64;
  static const int _sampleH = 48;
  static const int _neededStableFrames = 12; // ~1s if we process ~12fps
  static const double _diffThreshold = 6.0; // lower = stricter
  static const double _sharpnessThreshold = 12.0; // higher = stricter

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      await controller.startImageStream(_onFrame);
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _isInitializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop<String?>(null);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onFrame(CameraImage image) {
    if (_isCapturing) return;
    // Process only Y plane (luma) for speed.
    final plane = image.planes.first;
    final bytes = plane.bytes;
    final rowStride = plane.bytesPerRow;

    final sample = List<int>.filled(_sampleW * _sampleH, 0);
    final stepX = (image.width / _sampleW).floor().clamp(1, image.width);
    final stepY = (image.height / _sampleH).floor().clamp(1, image.height);

    var idx = 0;
    for (var sy = 0; sy < _sampleH; sy++) {
      final y = (sy * stepY).clamp(0, image.height - 1);
      final rowOff = y * rowStride;
      for (var sx = 0; sx < _sampleW; sx++) {
        final x = (sx * stepX).clamp(0, image.width - 1);
        sample[idx++] = bytes[rowOff + x];
      }
    }

    final sharp = _estimateSharpness(sample);
    final diff = _prevLuma == null ? 999.0 : _meanAbsDiff(_prevLuma!, sample);
    _prevLuma = sample;

    // Keep only the stable frame count; we don't show raw metrics in UI.

    final stable = diff < _diffThreshold && sharp > _sharpnessThreshold;
    _stableFrames = stable ? (_stableFrames + 1) : 0;

    if (_stableFrames >= _neededStableFrames) {
      _capture();
    } else {
      if (mounted) setState(() {});
    }
  }

  double _meanAbsDiff(List<int> a, List<int> b) {
    var sum = 0;
    for (var i = 0; i < a.length; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return sum / a.length;
  }

  // Simple sharpness proxy: average absolute gradient in the downsampled luma.
  double _estimateSharpness(List<int> luma) {
    double sum = 0;
    int count = 0;
    for (var y = 0; y < _sampleH - 1; y++) {
      for (var x = 0; x < _sampleW - 1; x++) {
        final i = y * _sampleW + x;
        final gx = (luma[i + 1] - luma[i]).abs();
        final gy = (luma[i + _sampleW] - luma[i]).abs();
        sum += gx + gy;
        count++;
      }
    }
    return count == 0 ? 0 : sum / count;
  }

  Future<void> _capture() async {
    if (_isCapturing || _previewPath != null) return;
    setState(() => _isCapturing = true);
    try {
      final c = _controller;
      if (c == null) return;
      try {
        await c.stopImageStream();
      } catch (_) {}
      final file = await c.takePicture();
      if (!mounted) return;
      setState(() {
        _previewPath = file.path;
        _isCapturing = false;
        _stableFrames = 0;
        _prevLuma = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isCapturing = false);
    }
  }

  Future<void> _retake() async {
    setState(() {
      _previewPath = null;
      _stableFrames = 0;
      _prevLuma = null;
    });
    final c = _controller;
    if (c != null && c.value.isInitialized) {
      try {
        await c.startImageStream(_onFrame);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final preview = _previewPath;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop<String?>(null),
        ),
        title: Text(preview == null ? 'Scan document' : 'Review document'),
        actions: preview == null
            ? [
                TextButton(
                  onPressed: _isCapturing ? null : _capture,
                  child: const Text('Capture now'),
                ),
              ]
            : null,
      ),
      body: _isInitializing || c == null
          ? const Center(child: CircularProgressIndicator())
          : preview != null
          ? Column(
              children: [
                Expanded(
                  child: Image.file(File(preview), fit: BoxFit.contain),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(preview),
                        child: const Text('Use this photo'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _retake,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retake'),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : Stack(
              children: [
                Positioned.fill(child: CameraPreview(c)),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: DefaultTextStyle(
                      style: const TextStyle(color: Colors.white),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
            Text(
                            _isCapturing
                                ? 'Capturing...'
                                : (_stableFrames >= _neededStableFrames
                                      ? 'Captured'
                                      : 'Hold steady…'),
            ),
          ],
        ),
      ),
                  ),
                ),
              ],
      ),
    );
  }
}
