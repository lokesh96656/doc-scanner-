import 'dart:io';
import 'dart:math' as math;

import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
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

enum _DocTemplate { auto, aadhaarIN, panIN, drivingLicenseIN, unknown }

String _templateLabel(_DocTemplate t) {
  switch (t) {
    case _DocTemplate.auto:
      return 'Auto';
    case _DocTemplate.aadhaarIN:
      return 'Aadhaar (India)';
    case _DocTemplate.panIN:
      return 'PAN (India)';
    case _DocTemplate.drivingLicenseIN:
      return 'Driving Licence (India)';
    case _DocTemplate.unknown:
      return 'Unknown';
  }
}

String _normalizeOcr(String s) {
  // Keep it simple: normalize whitespace and uppercase for keyword checks.
  return s.replaceAll('\r', '\n').replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

(_DocTemplate, double) _detectTemplate(String text) {
  final upper = text.toUpperCase();

  double scorePan = 0;
  double scoreAadhaar = 0;
  double scoreDl = 0;

  // PAN signals
  if (upper.contains('INCOME TAX')) scorePan += 2;
  if (upper.contains('PERMANENT ACCOUNT NUMBER')) scorePan += 2;
  if (RegExp(r'\b[A-Z]{5}[0-9]{4}[A-Z]\b').hasMatch(upper)) scorePan += 3;

  // Aadhaar signals
  if (upper.contains('UIDAI')) scoreAadhaar += 2;
  if (upper.contains('GOVERNMENT OF INDIA')) scoreAadhaar += 2;
  if (upper.contains('AADHAAR')) scoreAadhaar += 2;
  if (RegExp(r'\b[2-9][0-9]{3}\s?[0-9]{4}\s?[0-9]{4}\b').hasMatch(upper)) {
    scoreAadhaar += 3;
  }

  // Driving Licence signals (India-leaning keywords)
  if (upper.contains('DRIVING LICENCE') || upper.contains('DRIVING LICENSE')) {
    scoreDl += 2;
  }
  if (upper.contains('DL NO') || upper.contains('DLNO') || upper.contains('DL.')) {
    scoreDl += 2;
  }
  if (upper.contains('TRANSPORT')) scoreDl += 1;
  if (RegExp(r'\bLMV\b').hasMatch(upper)) scoreDl += 1;

  final best = math.max(scorePan, math.max(scoreAadhaar, scoreDl));
  if (best <= 2) return (_DocTemplate.unknown, 0.0);

  if (best == scoreAadhaar) return (_DocTemplate.aadhaarIN, (best / 8).clamp(0.0, 1.0));
  if (best == scorePan) return (_DocTemplate.panIN, (best / 8).clamp(0.0, 1.0));
  return (_DocTemplate.drivingLicenseIN, (best / 8).clamp(0.0, 1.0));
}

Map<String, String> _extractFields(_DocTemplate type, String text) {
  final upper = text.toUpperCase();
  switch (type) {
    case _DocTemplate.panIN:
      return _extractPanFields(upper, text);
    case _DocTemplate.aadhaarIN:
      return _extractAadhaarFields(upper, text);
    case _DocTemplate.drivingLicenseIN:
      return _extractDlFields(upper, text);
    case _DocTemplate.auto:
    case _DocTemplate.unknown:
      return const {};
  }
}

Map<String, bool> _validateFields(_DocTemplate type, Map<String, String> fields) {
  bool match(String key, RegExp re) => fields[key] != null && re.hasMatch(fields[key]!);

  switch (type) {
    case _DocTemplate.panIN:
      return {
        'PAN': match('PAN', RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]$')),
        'DOB': fields['DOB'] != null && fields['DOB']!.isNotEmpty,
        'Name': fields['Name'] != null && fields['Name']!.isNotEmpty,
      };
    case _DocTemplate.aadhaarIN:
      return {
        'Aadhaar': fields['Aadhaar'] != null &&
            RegExp(r'^[2-9][0-9]{11}$').hasMatch(fields['Aadhaar']!.replaceAll(' ', '')),
        'DOB/YOB': fields['DOB/YOB'] != null && fields['DOB/YOB']!.isNotEmpty,
        'Name': fields['Name'] != null && fields['Name']!.isNotEmpty,
      };
    case _DocTemplate.drivingLicenseIN:
      return {
        'DL No': fields['DL No'] != null && fields['DL No']!.length >= 8,
        'DOB': fields['DOB'] != null && fields['DOB']!.isNotEmpty,
        'Name': fields['Name'] != null && fields['Name']!.isNotEmpty,
      };
    case _DocTemplate.auto:
    case _DocTemplate.unknown:
      return const {};
  }
}

Map<String, String> _extractPanFields(String upper, String original) {
  final out = <String, String>{};
  final pan = RegExp(r'\b[A-Z]{5}[0-9]{4}[A-Z]\b').firstMatch(upper)?.group(0);
  if (pan != null) out['PAN'] = pan;

  // DOB often looks like DD/MM/YYYY or DD-MM-YYYY
  final dob = RegExp(r'\b[0-3]?\d[\/\-][0-1]?\d[\/\-](19|20)\d{2}\b')
      .firstMatch(original)
      ?.group(0);
  if (dob != null) out['DOB'] = dob;

  // Heuristic: pick longest ALLCAPS line that's not a header and not PAN.
  final lines = upper.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  final candidates = lines.where((l) {
    if (l.contains('INCOME TAX')) return false;
    if (l.contains('DEPARTMENT')) return false;
    if (l.contains('GOVT')) return false;
    if (pan != null && l.contains(pan)) return false;
    return RegExp(r'^[A-Z .]+$').hasMatch(l) && l.length >= 6;
  }).toList();
  if (candidates.isNotEmpty) {
    candidates.sort((a, b) => b.length.compareTo(a.length));
    out['Name'] = candidates.first.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
  return out;
}

Map<String, String> _extractAadhaarFields(String upper, String original) {
  final out = <String, String>{};
  final aadhaar = RegExp(r'\b[2-9][0-9]{3}\s?[0-9]{4}\s?[0-9]{4}\b')
      .firstMatch(original)
      ?.group(0);
  if (aadhaar != null) out['Aadhaar'] = aadhaar.replaceAll(RegExp(r'\s+'), ' ').trim();

  // DOB or YOB
  final dob = RegExp(r'\bDOB\s*[:\-]?\s*([0-3]?\d[\/\-][0-1]?\d[\/\-](19|20)\d{2})\b',
          caseSensitive: false)
      .firstMatch(original)
      ?.group(1);
  final yob = RegExp(r'\bYOB\s*[:\-]?\s*((19|20)\d{2})\b', caseSensitive: false)
      .firstMatch(original)
      ?.group(1);
  if (dob != null) {
    out['DOB/YOB'] = dob;
  } else if (yob != null) {
    out['DOB/YOB'] = yob;
  }

  final gender = RegExp(r'\b(MALE|FEMALE|TRANSGENDER)\b', caseSensitive: false)
      .firstMatch(original)
      ?.group(1);
  if (gender != null) out['Gender'] = gender;

  // Name: often first strong title-cased line before DOB/YOB.
  final lines = original
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  for (final l in lines) {
    final u = l.toUpperCase();
    if (u.contains('GOVERNMENT OF INDIA') || u.contains('UIDAI') || u.contains('AADHAAR')) {
      continue;
    }
    if (RegExp(r'\bDOB\b|\bYOB\b', caseSensitive: false).hasMatch(l)) break;
    if (RegExp(r'^[A-Za-z][A-Za-z .]{4,}$').hasMatch(l) && !RegExp(r'\d').hasMatch(l)) {
      out['Name'] = l.replaceAll(RegExp(r'\s+'), ' ').trim();
      break;
    }
  }
  return out;
}

Map<String, String> _extractDlFields(String upper, String original) {
  final out = <String, String>{};
  final dl = RegExp(r'\b([A-Z]{2}\s?[0-9]{2}\s?[0-9]{4,})\b')
      .firstMatch(upper)
      ?.group(1);
  if (dl != null) out['DL No'] = dl.replaceAll(RegExp(r'\s+'), '').trim();

  final dob = RegExp(r'\b[0-3]?\d[\/\-][0-1]?\d[\/\-](19|20)\d{2}\b')
      .firstMatch(original)
      ?.group(0);
  if (dob != null) out['DOB'] = dob;

  // Name guess: first title-cased-ish line after "Name" label if present.
  final nameMatch = RegExp(r'\bNAME\b\s*[:\-]?\s*([A-Za-z .]{4,})', caseSensitive: false)
      .firstMatch(original);
  if (nameMatch != null) {
    out['Name'] = nameMatch.group(1)!.trim();
    return out;
  }

  // Fallback: first alpha line with no digits, not headers.
  final lines = original
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  for (final l in lines) {
    final u = l.toUpperCase();
    if (u.contains('DRIVING') || u.contains('LICENCE') || u.contains('LICENSE')) continue;
    if (u.contains('UNION') || u.contains('TRANSPORT')) continue;
    if (RegExp(r'\d').hasMatch(l)) continue;
    if (l.length < 5) continue;
    if (RegExp(r'^[A-Za-z][A-Za-z .]+$').hasMatch(l)) {
      out['Name'] = l.replaceAll(RegExp(r'\s+'), ' ').trim();
      break;
    }
  }
  return out;
}

class _CropDocumentScreen extends StatefulWidget {
  const _CropDocumentScreen({required this.imagePath});

  final String imagePath;

  @override
  State<_CropDocumentScreen> createState() => _CropDocumentScreenState();
}

class _CropDocumentScreenState extends State<_CropDocumentScreen> {
  List<Offset>? _corners;
  List<Offset>? _autoCorners01; // normalized (0..1) topLeft, topRight, bottomRight, bottomLeft
  Size? _viewSize;
  bool _hasUserAdjustedCorners = false;

  static const double _handleSize = 20;
  /// Minimum inset from screen edges for the **center** of each handle so the
  /// touch target stays on-screen and drags work at extreme left/right.
  static const double _cornerCenterInset = 26;
  /// Material-like min touch target (visual handle stays smaller, centered).
  static const double _touchTarget = 48;
  static const double _minEdge = 30;

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
      final ocrAuto01 = _detectAutoCornersFromText(result, decoded.width, decoded.height);
      // 2) If OCR is weak, try an edge-based rectangle.
      final auto01 = ocrAuto01 ?? _detectAutoCornersFromEdges(decoded);
      if (auto01 == null) return;

      if (!mounted) return;
      setState(() {
        _autoCorners01 = auto01;
        // Apply automatically unless user has already moved corners manually.
        if (!_hasUserAdjustedCorners && _viewSize != null) {
          _corners = auto01
              .map((p) => Offset(p.dx * _viewSize!.width, p.dy * _viewSize!.height))
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
      if (pts == null || pts.isEmpty) continue;
      for (final p in pts) {
        final x = p.x.toDouble();
        final y = p.y.toDouble();
        minX = minX == null ? x : math.min(minX!, x);
        minY = minY == null ? y : math.min(minY!, y);
        maxX = maxX == null ? x : math.max(maxX!, x);
        maxY = maxY == null ? y : math.max(maxY!, y);
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
    final padX = (maxX! - minX!) * 0.06;
    final padY = (maxY! - minY!) * 0.10;

    final left = (minX! - padX).clamp(0.0, width.toDouble());
    final top = (minY! - padY).clamp(0.0, height.toDouble());
    final right = (maxX! + padX).clamp(0.0, width.toDouble());
    final bottom = (maxY! + padY).clamp(0.0, height.toDouble());

    return _buildValidatedAutoRect(left, top, right, bottom, width.toDouble(), height.toDouble());
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
      (left! - mx).clamp(0, w - 2),
      (top! - my).clamp(0, h - 2),
      (right! + mx).clamp(2, w - 1),
      (bottom! + my).clamp(2, h - 1),
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
        s += (gray.getPixel(x, y).r - gray.getPixel(x, y - 1).r).abs().toDouble();
      }
      return s;
    }

    double vertStrength(int x) {
      if (x <= 0 || x >= w - 1) return 0;
      var s = 0.0;
      for (var y = y0; y < y1; y++) {
        s += (gray.getPixel(x, y).r - gray.getPixel(x - 1, y).r).abs().toDouble();
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

    final srcQuad = corners.map((o) => Offset(o.dx * scaleX, o.dy * scaleY)).toList();

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

  _DocTemplate _detectedTemplate = _DocTemplate.unknown;
  double? _templateConfidence;
  Map<String, String> _extractedFields = const {};
  Map<String, bool> _fieldValid = const {};

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
      final String? capturedPath = await Navigator.of(context).push<String?>(
        MaterialPageRoute(builder: (_) => const _AutoCaptureCameraScreen()),
      );

      if (capturedPath == null) {
        return;
      }
      final pickedFile = XFile(capturedPath);

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
      _runTemplatePipeline(recognizedText.text);
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _recognizedText = 'Error: $e';
      });
    }
  }

  void _runTemplatePipeline(String ocrText) {
    final normalized = _normalizeOcr(ocrText);
    final (_DocTemplate type, double confidence) = _detectTemplate(normalized);

    final fields = _extractFields(type, normalized);
    final validity = _validateFields(type, fields);

    setState(() {
      _detectedTemplate = type;
      _templateConfidence = confidence;
      _extractedFields = fields;
      _fieldValid = validity;
    });
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
            if (_recognizedText.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Detected: ${_templateLabel(_detectedTemplate)}',
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
                          Expanded(
                            child: Text('${e.key}: ${e.value}'),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
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

class _AutoCaptureCameraScreen extends StatefulWidget {
  const _AutoCaptureCameraScreen();

  @override
  State<_AutoCaptureCameraScreen> createState() => _AutoCaptureCameraScreenState();
}

class _AutoCaptureCameraScreenState extends State<_AutoCaptureCameraScreen> {
  CameraController? _controller;
  bool _isInitializing = true;
  bool _isCapturing = false;

  // Stability/blur checks
  List<int>? _prevLuma; // small grayscale sample
  int _stableFrames = 0;
  double _lastDiff = 999;
  double _lastSharpness = 0;

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

    _lastDiff = diff;
    _lastSharpness = sharp;

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
    if (_isCapturing) return;
    setState(() => _isCapturing = true);
    try {
      final c = _controller;
      if (c == null) return;
      await c.stopImageStream();
      final file = await c.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop<String>(file.path);
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pop<String?>(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Auto Capture'),
        actions: [
          TextButton(
            onPressed: _isCapturing ? null : _capture,
            child: const Text('Capture now'),
          )
        ],
      ),
      body: _isInitializing || c == null
          ? const Center(child: CircularProgressIndicator())
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
                      color: Colors.black.withOpacity(0.55),
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
