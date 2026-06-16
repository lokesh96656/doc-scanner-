import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import 'face_aligner.dart';

class FaceQualityIssue {
  const FaceQualityIssue(this.message);
  final String message;
}

/// AWS-style gating: pose, size, landmarks, and blur before embedding.
FaceQualityIssue? checkFaceQuality(
  Face face, {
  required int imageWidth,
  required int imageHeight,
  required img.Image decoded,
  bool isDocumentPortrait = false,
}) {
  final box = face.boundingBox;
  final imageArea = imageWidth * imageHeight;
  final faceArea = box.width * box.height;
  final areaRatio = faceArea / imageArea;

  final minRatio = isDocumentPortrait ? 0.004 : 0.012;
  if (areaRatio < minRatio) {
    return FaceQualityIssue(
      isDocumentPortrait
          ? 'Portrait on document is too small. Move closer or use a higher-resolution photo.'
          : 'Face is too small in frame. Move closer to the camera.',
    );
  }

  final yaw = face.headEulerAngleY;
  final pitch = face.headEulerAngleX;
  final roll = face.headEulerAngleZ;
  if (yaw != null && yaw.abs() > 32) {
    return const FaceQualityIssue(
      'Face turned too far to the side. Look straight at the camera.',
    );
  }
  if (pitch != null && pitch.abs() > 28) {
    return const FaceQualityIssue(
      'Hold the phone level and look straight ahead.',
    );
  }
  if (roll != null && roll.abs() > 28) {
    return const FaceQualityIssue(
      'Keep your head upright (avoid strong tilt).',
    );
  }

  final landmarks = collectFivePointLandmarks(face);
  if (landmarks == null || landmarks.length < 2) {
    return const FaceQualityIssue(
      'Could not detect eyes clearly. Improve lighting and face the camera.',
    );
  }

  final sharpness = _laplacianVarianceOnFace(decoded, face);
  final minSharp = isDocumentPortrait ? 18.0 : 22.0;
  if (sharpness < minSharp) {
    return FaceQualityIssue(
      isDocumentPortrait
          ? 'ID portrait is too blurry. Use sharper lighting and hold still.'
          : 'Image is too blurry. Hold still and ensure good lighting.',
    );
  }

  return null;
}

double _laplacianVarianceOnFace(img.Image source, Face face) {
  final box = face.boundingBox;
  final padX = box.width * 0.1;
  final padY = box.height * 0.1;
  var left = (box.left - padX).floor();
  var top = (box.top - padY).floor();
  var right = (box.right + padX).ceil();
  var bottom = (box.bottom + padY).ceil();

  left = left.clamp(0, source.width - 1);
  top = top.clamp(0, source.height - 1);
  right = right.clamp(left + 1, source.width);
  bottom = bottom.clamp(top + 1, source.height);

  final w = right - left;
  final h = bottom - top;
  if (w < 8 || h < 8) return 0;

  final crop = img.copyCrop(source, x: left, y: top, width: w, height: h);
  final small = img.copyResize(crop, width: 64, height: 64);
  final gray = img.grayscale(small);

  var sum = 0.0;
  var sumSq = 0.0;
  var count = 0;

  for (var y = 1; y < gray.height - 1; y++) {
    for (var x = 1; x < gray.width - 1; x++) {
      final c = gray.getPixel(x, y).r.toDouble();
      final lap = -4 * c +
          gray.getPixel(x - 1, y).r +
          gray.getPixel(x + 1, y).r +
          gray.getPixel(x, y - 1).r +
          gray.getPixel(x, y + 1).r;
      sum += lap;
      sumSq += lap * lap;
      count++;
    }
  }
  if (count == 0) return 0;
  final mean = sum / count;
  return sumSq / count - mean * mean;
}

/// Picks the largest face that passes minimum area; ignores tiny false detections.
Face? selectPrimaryFace(
  List<Face> faces, {
  required int imageWidth,
  required int imageHeight,
  double minAreaRatio = 0.008,
}) {
  if (faces.isEmpty) return null;
  final imageArea = imageWidth * imageHeight;
  Face? best;
  var bestArea = 0.0;
  for (final f in faces) {
    final box = f.boundingBox;
    final area = box.width * box.height;
    final ratio = area / imageArea;
    if (ratio < minAreaRatio) continue;
    if (area > bestArea) {
      bestArea = area;
      best = f;
    }
  }
  return best ?? _largestFaceUnchecked(faces);
}

Face _largestFaceUnchecked(List<Face> faces) {
  Face best = faces.first;
  var bestArea = 0.0;
  for (final f in faces) {
    final area = f.boundingBox.width * f.boundingBox.height;
    if (area > bestArea) {
      bestArea = area;
      best = f;
    }
  }
  return best;
}

/// Ignores spurious small faces when the main face dominates the frame.
bool shouldRejectExtraFaces(
  List<Face> faces,
  Face primary, {
  required int imageWidth,
  required int imageHeight,
}) {
  if (faces.length <= 1) return false;
  final primaryArea = primary.boundingBox.width * primary.boundingBox.height;
  final imageArea = imageWidth * imageHeight;
  for (final f in faces) {
    if (identical(f, primary)) continue;
    final area = f.boundingBox.width * f.boundingBox.height;
    if (area / imageArea > 0.02 && area > primaryArea * 0.35) {
      return true;
    }
  }
  return false;
}
