import 'dart:io';
import 'dart:math' as math;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Detects tilt angle (degrees) from text block orientation in the cropped image.
Future<double> detectTiltAngle(img.Image image) async {
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
