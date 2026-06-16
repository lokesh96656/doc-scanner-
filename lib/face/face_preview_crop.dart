import 'dart:io';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'face_image_utils.dart';
import 'face_quality.dart';

/// Auto-crops the largest face from a combined selfie+document photo for UI preview.
Future<File?> autoCropSelfieFacePreview(String combinedPath) async {
  try {
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.08,
        enableLandmarks: true,
      ),
    );
    final faces = await detector.processImage(
      InputImage.fromFilePath(combinedPath),
    );
    detector.close();
    if (faces.isEmpty) return null;

    final decoded = loadOrientedImage(combinedPath);
    if (decoded == null) return null;

    final best = selectPrimaryFace(
      faces,
      imageWidth: decoded.width,
      imageHeight: decoded.height,
      minAreaRatio: 0.008,
    );
    if (best == null) return null;

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
