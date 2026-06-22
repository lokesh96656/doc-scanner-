import 'dart:io';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'face_image_utils.dart';

/// Upright pixels plus a JPEG path that matches them exactly for ML Kit.
class FaceAnalysisImage {
  const FaceAnalysisImage({
    required this.pixels,
    required this.analysisPath,
  });

  final img.Image pixels;

  /// Temp file (no EXIF rotation); use with [InputImage.fromFilePath].
  final String analysisPath;
}

/// Ensures face landmarks and pixel buffers use the same upright coordinates.
Future<FaceAnalysisImage?> loadFaceAnalysisImage(String path) async {
  final baked = loadOrientedImage(path);
  if (baked == null) return null;

  final dir = await getTemporaryDirectory();
  final outPath =
      '${dir.path}/face_ml_${DateTime.now().millisecondsSinceEpoch}.jpg';
  await File(outPath).writeAsBytes(img.encodeJpg(baked, quality: 92));

  return FaceAnalysisImage(pixels: baked, analysisPath: outPath);
}

Future<List<Face>> detectFaces(FaceDetector detector, FaceAnalysisImage image) {
  return detector.processImage(InputImage.fromFilePath(image.analysisPath));
}
