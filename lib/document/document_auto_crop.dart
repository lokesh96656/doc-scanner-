import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'document_corner_detector.dart';
import '../face/face_image_utils.dart';

/// Automatic document crop for selfie+ID flow (no manual corner UI).
class DocumentAutoCrop {
  const DocumentAutoCrop._();

  static Future<File?> cropFromPhoto({
    required String imagePath,
    required TextRecognizer textRecognizer,
  }) async {
    try {
      final decoded = loadOrientedImage(imagePath);
      if (decoded == null) return null;

      RecognizedText? ocrResult;
      try {
        ocrResult =
            await textRecognizer.processImage(InputImage.fromFilePath(imagePath));
      } catch (_) {
        ocrResult = null;
      }

      final rect = DocumentCornerDetector.detectDocumentRect(
        ocrResult: ocrResult,
        decoded: decoded,
      );
      if (rect == null) return null;
      final (left, top, right, bottom) = rect;

      final cropped = img.copyCrop(
        decoded,
        x: left,
        y: top,
        width: (right - left).clamp(1, decoded.width),
        height: (bottom - top).clamp(1, decoded.height),
      );

      final enhanced = img.adjustColor(cropped, contrast: 1.15);

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
}
