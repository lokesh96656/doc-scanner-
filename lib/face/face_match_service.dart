import 'dart:math' as math;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'face_aligner.dart';
import 'face_image_utils.dart';
import 'face_quality.dart';

/// On-device face comparison: ML Kit + 5-point alignment + MobileFaceNet embeddings.
class FaceMatchResult {
  const FaceMatchResult({
    this.matchPercent,
    this.pass,
    this.error,
    this.usedEmbeddingModel = false,
    this.distance,
    this.cosineSimilarity,
  });

  final double? matchPercent;
  final bool? pass;
  final String? error;
  final bool usedEmbeddingModel;

  /// L2 distance between embeddings (lower = more similar). For debugging/tuning.
  final double? distance;

  /// Cosine similarity on L2-normalized embeddings (higher = more similar).
  final double? cosineSimilarity;

  /// Same-person if cosine similarity is at or above this (≈ distance 0.98).
  static const double matchCosineThreshold = 0.52;

  /// Cosine at or below this maps to ~0% in the UI.
  static const double displayMinCosine = 0.38;

  /// Cosine at or above this maps to ~100% in the UI.
  static const double displayMaxCosine = 0.92;
}

class FaceMatchService {
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
      final idDecoded = loadOrientedImage(idImagePath);
      final selfieDecoded = loadOrientedImage(selfieImagePath);
      if (idDecoded == null || selfieDecoded == null) {
        return const FaceMatchResult(error: 'Could not read image files');
      }

      final idFaces = await detector.processImage(
        InputImage.fromFilePath(idImagePath),
      );
      if (idFaces.isEmpty) {
        return const FaceMatchResult(
          error: 'No face found on ID. Use a clearer photo of the portrait.',
        );
      }

      final selfieFaces = await detector.processImage(
        InputImage.fromFilePath(selfieImagePath),
      );
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

      final idAligned = alignFaceTo112(idDecoded, idFace);
      if (idAligned == null) {
        return const FaceMatchResult(error: 'Could not align ID portrait');
      }

      final idVec = _embedWithTflite(_interpreter!, idAligned);
      final match = _bestSelfieMatch(
        interpreter: _interpreter!,
        idVec: idVec,
        selfieDecoded: selfieDecoded,
        selfieFace: selfieFace,
      );
      if (match == null) {
        return const FaceMatchResult(error: 'Could not align selfie face');
      }

      final pass = match.cosine >= FaceMatchResult.matchCosineThreshold;
      final percent = _cosineToPercent(match.cosine);

      return FaceMatchResult(
        matchPercent: percent,
        pass: pass,
        usedEmbeddingModel: true,
        distance: match.distance,
        cosineSimilarity: match.cosine,
      );
    } catch (e) {
      return FaceMatchResult(error: 'Face match failed: $e');
    }
  }

  /// Tries normal + horizontally mirrored selfie (front camera mirror fix).
  _EmbeddingMatch? _bestSelfieMatch({
    required Interpreter interpreter,
    required List<double> idVec,
    required img.Image selfieDecoded,
    required Face selfieFace,
  }) {
    _EmbeddingMatch? best;

    void consider(img.Image? aligned) {
      if (aligned == null) return;
      final vec = _embedWithTflite(interpreter, aligned);
      final distance = _euclideanDistance(idVec, vec);
      final cosine = _cosineSimilarity(idVec, vec);
      if (best == null || cosine > best!.cosine) {
        best = _EmbeddingMatch(distance: distance, cosine: cosine);
      }
    }

    consider(alignFaceTo112(selfieDecoded, selfieFace));
    consider(alignFaceTo112Mirrored(selfieDecoded, selfieFace));

    return best;
  }

  double _cosineToPercent(double cosine) {
    final low = FaceMatchResult.displayMinCosine;
    final high = FaceMatchResult.displayMaxCosine;
    if (cosine >= high) return 100;
    if (cosine <= low) return 0;
    return ((cosine - low) / (high - low) * 100).clamp(0.0, 100.0);
  }

  List<double> _embedWithTflite(Interpreter interpreter, img.Image face112) {
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (y) => List.generate(_inputSize, (x) {
          final p = face112.getPixel(x, y);
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
