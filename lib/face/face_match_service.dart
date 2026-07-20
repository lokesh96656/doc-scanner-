import 'dart:math' as math;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'face_aligner.dart';
import 'face_image_loader.dart';
import 'face_match_result.dart';

export 'face_match_result.dart';
import 'face_quality.dart';

/// On-device face comparison: ML Kit + 5-point alignment + MobileFaceNet embeddings.
class FaceMatchService {
  /// Same-person decision threshold (raw cosine on L2-normalized embeddings).
  static const double _matchCosineThreshold = 0.52;

  FaceDetector? _detector;
  Interpreter? _interpreter;
  bool _interpreterReady = false;

  static const int _inputSize = 112;
  static const String _modelAsset = 'assets/models/mobilefacenet.tflite';

  Future<void> init() async {
    _detector ??= FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.08,
        enableLandmarks: true,
      ),
    );
    if (_interpreter != null) return;
    try {
      final interpreter = await Interpreter.fromAsset(_modelAsset);
      final inShape = interpreter.getInputTensor(0).shape;
      if (inShape.length < 4 || inShape[1] != _inputSize) {
        interpreter.close();
        _interpreterReady = false;
        return;
      }
      _interpreter = interpreter;
      _interpreterReady = true;
    } catch (_) {
      _interpreterReady = false;
    }
  }

  void dispose() {
    _detector?.close();
    _detector = null;
    _interpreter?.close();
    _interpreter = null;
    _interpreterReady = false;
  }

  Future<FaceMatchResult> compare({
    required String idImagePath,
    required String selfieImagePath,
  }) async {
    return _compareInternal(
      idImagePath: idImagePath,
      selfieImagePath: selfieImagePath,
      allowMultipleFacesInSelfie: false,
    );
  }

  Future<FaceMatchResult> compareSelfieWithDocument({
    required String combinedSelfieWithDocPath,
    required String croppedDocumentPath,
  }) async {
    return _compareInternal(
      idImagePath: croppedDocumentPath,
      selfieImagePath: combinedSelfieWithDocPath,
      allowMultipleFacesInSelfie: true,
    );
  }

  Future<FaceMatchResult> _compareInternal({
    required String idImagePath,
    required String selfieImagePath,
    required bool allowMultipleFacesInSelfie,
  }) async {
    await init();
    final detector = _detector;
    if (detector == null) {
      return const FaceMatchResult(error: 'Face detector not available');
    }
    if (!_interpreterReady || _interpreter == null) {
      return const FaceMatchResult(
        error:
            'Face embedding model not loaded. Rebuild the app with mobilefacenet.tflite.',
      );
    }

    try {
      final idImage = await loadFaceAnalysisImage(idImagePath);
      final selfieImage = await loadFaceAnalysisImage(selfieImagePath);
      if (idImage == null || selfieImage == null) {
        return const FaceMatchResult(error: 'Could not read image files');
      }

      final idDecoded = idImage.pixels;
      final selfieDecoded = selfieImage.pixels;

      final idFaces = await detectFaces(detector, idImage);
      if (idFaces.isEmpty) {
        return const FaceMatchResult(
          error: 'No face found on ID. Use a clearer photo of the portrait.',
        );
      }

      final selfieFaces = await detectFaces(detector, selfieImage);
      if (selfieFaces.isEmpty) {
        return const FaceMatchResult(
          error: 'No face found in selfie. Please retake facing the camera.',
        );
      }

      final idFace = selectPrimaryFace(
        idFaces,
        imageWidth: idDecoded.width,
        imageHeight: idDecoded.height,
        minAreaRatio: 0.003,
      );
      if (idFace == null) {
        return const FaceMatchResult(
          error: 'No usable face on ID document.',
        );
      }

      final selfieFace = selectPrimaryFace(
        selfieFaces,
        imageWidth: selfieDecoded.width,
        imageHeight: selfieDecoded.height,
        minAreaRatio: allowMultipleFacesInSelfie ? 0.008 : 0.012,
      );
      if (selfieFace == null) {
        return const FaceMatchResult(
          error: 'No usable face in selfie photo.',
        );
      }

      if (!allowMultipleFacesInSelfie &&
          shouldRejectExtraFaces(
            selfieFaces,
            selfieFace,
            imageWidth: selfieDecoded.width,
            imageHeight: selfieDecoded.height,
          )) {
        return const FaceMatchResult(
          error: 'Multiple faces in selfie. Only one person should be visible.',
        );
      }

      final idQuality = checkFaceQuality(
        idFace,
        imageWidth: idDecoded.width,
        imageHeight: idDecoded.height,
        decoded: idDecoded,
        isDocumentPortrait: true,
      );
      if (idQuality != null) {
        return FaceMatchResult(error: idQuality.message);
      }

      final selfieQuality = checkFaceQuality(
        selfieFace,
        imageWidth: selfieDecoded.width,
        imageHeight: selfieDecoded.height,
        decoded: selfieDecoded,
        isDocumentPortrait: false,
      );
      if (selfieQuality != null) {
        return FaceMatchResult(error: selfieQuality.message);
      }

      final match = _bestFacePairMatch(
        interpreter: _interpreter!,
        idDecoded: idDecoded,
        idFace: idFace,
        selfieDecoded: selfieDecoded,
        selfieFace: selfieFace,
      );
      if (match == null) {
        return const FaceMatchResult(error: 'Could not align selfie face');
      }

      final pass = match.cosine >= _matchCosineThreshold;
      final percent = _cosineToPercent(match.cosine);

      return FaceMatchResult(
        matchPercent: percent,
        pass: pass,
        usedEmbeddingModel: true,
        distance: match.distance,
        cosineSimilarity: match.cosine,
        provider: 'MobileFaceNet',
      );
    } catch (e) {
      return FaceMatchResult(error: 'Face match failed: $e');
    }
  }

  /// Tries normal/mirrored alignment for ID and selfie (camera + print fixes).
  _EmbeddingMatch? _bestFacePairMatch({
    required Interpreter interpreter,
    required img.Image idDecoded,
    required Face idFace,
    required img.Image selfieDecoded,
    required Face selfieFace,
  }) {
    _EmbeddingMatch? best;

    void consider(List<double> idVec, List<double> selfieVec) {
      final distance = _euclideanDistance(idVec, selfieVec);
      final cosine = _cosineSimilarity(idVec, selfieVec);
      if (best == null || cosine > best!.cosine) {
        best = _EmbeddingMatch(distance: distance, cosine: cosine);
      }
    }

    void tryPair(img.Image? idAligned, img.Image? selfieAligned) {
      if (idAligned == null || selfieAligned == null) return;
      consider(
        _embedWithTflite(interpreter, idAligned),
        _embedWithTflite(interpreter, selfieAligned),
      );
    }

    final idNormal = alignFaceTo112(idDecoded, idFace);
    final idMirrored = alignFaceTo112Mirrored(idDecoded, idFace);
    final selfieNormal = alignFaceTo112(selfieDecoded, selfieFace);
    final selfieMirrored = alignFaceTo112Mirrored(selfieDecoded, selfieFace);

    tryPair(idNormal, selfieNormal);
    tryPair(idNormal, selfieMirrored);
    tryPair(idMirrored, selfieNormal);
    tryPair(idMirrored, selfieMirrored);

    return best;
  }

  /// Maps cosine → UI % so same-person pairs (often 0.70–0.90) land near AWS-like
  /// high scores, while different people stay low.
  ///
  /// Previous linear map (0.38→0%, 0.92→100%) crushed a solid ~0.79 cosine to ~76%.
  double _cosineToPercent(double cosine) {
    if (cosine >= 0.85) return 100;
    if (cosine >= 0.75) {
      // Strong same-person (selfie↔selfie / clear ID): 92–100%
      return 92 + (cosine - 0.75) / 0.10 * 8;
    }
    if (cosine >= _matchCosineThreshold) {
      // Pass band: 80–92%
      return 80 +
          (cosine - _matchCosineThreshold) /
              (0.75 - _matchCosineThreshold) *
              12;
    }
    if (cosine >= 0.38) {
      // Below pass: 0–79%
      return (cosine - 0.38) / (_matchCosineThreshold - 0.38) * 79;
    }
    return 0;
  }

  List<double> _embedWithTflite(Interpreter interpreter, img.Image face112) {
    // Light normalize brightness so lighting / mono vs color gaps hurt less.
    final prepared = _normalizeFaceLighting(face112);
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (y) => List.generate(_inputSize, (x) {
          final p = prepared.getPixel(x, y);
          return [
            (p.r.toDouble() - 127.5) / 128.0,
            (p.g.toDouble() - 127.5) / 128.0,
            (p.b.toDouble() - 127.5) / 128.0,
          ];
        }),
      ),
    );

    final outLen = interpreter.getOutputTensor(0).shape.reduce((a, b) => a * b);
    final output = [List<double>.filled(outLen, 0)];
    interpreter.run(input, output);
    return _l2Normalize(List<double>.from(output[0]));
  }

  /// Scales RGB toward mid brightness without destroying color (helps mono/color pairs).
  img.Image _normalizeFaceLighting(img.Image src) {
    var sum = 0.0;
    var count = 0;
    for (var y = 0; y < src.height; y += 2) {
      for (var x = 0; x < src.width; x += 2) {
        final p = src.getPixel(x, y);
        sum += (p.r + p.g + p.b) / 3.0;
        count++;
      }
    }
    if (count == 0) return src;
    final mean = sum / count;
    if (mean < 1) return src;
    final scale = (127.5 / mean).clamp(0.75, 1.35);
    if ((scale - 1.0).abs() < 0.05) return src;

    final out = img.Image(width: src.width, height: src.height);
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        final p = src.getPixel(x, y);
        out.setPixelRgba(
          x,
          y,
          (p.r * scale).round().clamp(0, 255),
          (p.g * scale).round().clamp(0, 255),
          (p.b * scale).round().clamp(0, 255),
          p.a.toInt(),
        );
      }
    }
    return out;
  }

  List<double> _l2Normalize(List<double> v) {
    var sumSq = 0.0;
    for (final x in v) {
      sumSq += x * x;
    }
    final norm = math.sqrt(sumSq);
    if (norm < 1e-9) return v;
    return v.map((e) => e / norm).toList(growable: false);
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    final n = a.length < b.length ? a.length : b.length;
    if (n == 0) return -1;
    var dot = 0.0;
    for (var i = 0; i < n; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  double _euclideanDistance(List<double> a, List<double> b) {
    final n = a.length < b.length ? a.length : b.length;
    if (n == 0) return double.infinity;
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final d = a[i] - b[i];
      sum += d * d;
    }
    return math.sqrt(sum);
  }
}

class _EmbeddingMatch {
  const _EmbeddingMatch({required this.distance, required this.cosine});
  final double distance;
  final double cosine;
}
