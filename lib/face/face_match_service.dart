import 'dart:io';
import 'dart:math' as math;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// On-device face comparison: ML Kit detection + MobileFaceNet embeddings.
class FaceMatchResult {
  const FaceMatchResult({
    this.matchPercent,
    this.pass,
    this.error,
    this.usedEmbeddingModel = false,
    this.distance,
  });

  final double? matchPercent;
  final bool? pass;
  final String? error;
  final bool usedEmbeddingModel;

  /// L2 distance between embeddings (lower = more similar). For debugging/tuning.
  final double? distance;

  /// Same-person if Euclidean distance on normalized embeddings is below this.
  static const double matchDistanceThreshold = 1.0;

  /// Distances above this are treated as 0% match in the UI scale.
  static const double displayMaxDistance = 1.6;
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
        minFaceSize: 0.15,
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

  /// Used for "selfie with document" mode:
  /// - `selfieImagePath`: the combined photo (face + document)
  /// - `idImagePath`: the cropped document image (after perspective warp)
  ///
  /// We select the *largest* face in the combined photo as the selfie face,
  /// and compare it with the face detected on the cropped document.
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
      final idBytes = await File(idImagePath).readAsBytes();
      final selfieBytes = await File(selfieImagePath).readAsBytes();
      final idDecoded = img.decodeImage(idBytes);
      final selfieDecoded = img.decodeImage(selfieBytes);
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
      if (!allowMultipleFacesInSelfie && selfieFaces.length > 1) {
        return const FaceMatchResult(
          error: 'Multiple faces in selfie. Only one person should be visible.',
        );
      }

      final idFace = _largestFace(idFaces);
      final selfieFace = _largestFace(selfieFaces);

      final idAligned = _prepareAlignedFace(idDecoded, idFace);
      final selfieAligned = _prepareAlignedFace(selfieDecoded, selfieFace);
      if (idAligned == null || selfieAligned == null) {
        return const FaceMatchResult(error: 'Could not prepare face images');
      }

      final idVec = _embedWithTflite(_interpreter!, idAligned);
      final selfieVec = _embedWithTflite(_interpreter!, selfieAligned);

      final distance = _euclideanDistance(idVec, selfieVec);
      final pass = distance < FaceMatchResult.matchDistanceThreshold;
      final percent = _distanceToPercent(distance);

      return FaceMatchResult(
        matchPercent: percent,
        pass: pass,
        usedEmbeddingModel: true,
        distance: distance,
      );
    } catch (e) {
      return FaceMatchResult(error: 'Face match failed: $e');
    }
  }

  /// Maps L2 distance to 0–100% for display (calibrated for MobileFaceNet).
  double _distanceToPercent(double distance) {
    const maxD = FaceMatchResult.displayMaxDistance;
    final t = FaceMatchResult.matchDistanceThreshold;
    if (distance <= 0) return 100;
    if (distance >= maxD) return 0;
    // 100% at distance 0, ~50% at threshold, 0% at maxD.
    if (distance <= t) {
      return (100 * (1 - distance / (2 * t))).clamp(0.0, 100.0);
    }
    return (100 * (1 - distance / maxD)).clamp(0.0, 100.0);
  }

  Face _largestFace(List<Face> faces) {
    Face best = faces.first;
    var bestArea = 0.0;
    for (final f in faces) {
      final box = f.boundingBox;
      final area = box.width * box.height;
      if (area > bestArea) {
        bestArea = area;
        best = f;
      }
    }
    return best;
  }

  /// Crop, rotate using eye landmarks, then resize to model input.
  img.Image? _prepareAlignedFace(img.Image source, Face face) {
    final crop = _cropFace(source, face);
    if (crop == null) return null;

    final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;

    img.Image work = crop;
    if (leftEye != null && rightEye != null) {
      final box = face.boundingBox;
      final padX = box.width * 0.2;
      final padY = box.height * 0.25;
      final cropLeft = (box.left - padX).floor();
      final cropTop = (box.top - padY).floor();

      final lx = leftEye.x - cropLeft;
      final ly = leftEye.y - cropTop;
      final rx = rightEye.x - cropLeft;
      final ry = rightEye.y - cropTop;

      final angleDeg = math.atan2(ry - ly, rx - lx) * 180 / math.pi;
      work = img.copyRotate(crop, angle: -angleDeg);
    }

    return img.copyResize(
      work,
      width: _inputSize,
      height: _inputSize,
      interpolation: img.Interpolation.linear,
    );
  }

  img.Image? _cropFace(img.Image source, Face face) {
    final box = face.boundingBox;
    final padX = box.width * 0.25;
    final padY = box.height * 0.3;
    var left = (box.left - padX).floor();
    var top = (box.top - padY).floor();
    var right = (box.right + padX).ceil();
    var bottom = (box.bottom + padY).ceil();

    left = left.clamp(0, source.width - 1);
    top = top.clamp(0, source.height - 1);
    right = right.clamp(left + 1, source.width);
    bottom = bottom.clamp(top + 1, source.height);

    return img.copyCrop(
      source,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
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
