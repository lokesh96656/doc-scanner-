import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import '../document/image_warp.dart';

/// Canonical 5-point template for 112×112 face recognition (MobileFaceNet / InsightFace).
const List<Offset> kFaceTemplate112 = [
  Offset(38.2946, 51.6963), // left eye
  Offset(73.5318, 51.5014), // right eye
  Offset(56.0252, 71.7366), // nose base
  Offset(41.5493, 92.3655), // mouth left
  Offset(70.7299, 92.2041), // mouth right
];

/// Mirrors landmark X coords for a horizontally flipped image (swap left/right features).
List<Offset>? mirrorLandmarkPoints(List<Offset> src, int imageWidth) {
  if (src.length != 2 && src.length != 5) return null;
  final w = imageWidth.toDouble();
  Offset flip(Offset p) => Offset(w - 1 - p.dx, p.dy);

  if (src.length == 2) {
    return [flip(src[1]), flip(src[0])];
  }
  return [
    flip(src[1]),
    flip(src[0]),
    flip(src[2]),
    flip(src[4]),
    flip(src[3]),
  ];
}

/// Collects 5 landmark positions in full-image coordinates, or null if incomplete.
List<Offset>? collectFivePointLandmarks(Face face) {
  Offset? lm(FaceLandmarkType type) {
    final landmark = face.landmarks[type];
    if (landmark == null) return null;
    final p = landmark.position;
    return Offset(p.x.toDouble(), p.y.toDouble());
  }

  final leftEye = lm(FaceLandmarkType.leftEye);
  final rightEye = lm(FaceLandmarkType.rightEye);
  final nose = lm(FaceLandmarkType.noseBase);
  final mouthLeft = lm(FaceLandmarkType.leftMouth);
  final mouthRight = lm(FaceLandmarkType.rightMouth);

  if (leftEye != null &&
      rightEye != null &&
      nose != null &&
      mouthLeft != null &&
      mouthRight != null) {
    return [leftEye, rightEye, nose, mouthLeft, mouthRight];
  }

  if (leftEye != null && rightEye != null) {
    return [leftEye, rightEye];
  }
  return null;
}

/// Estimates 2D similarity transform: dst ≈ M·src + t.
/// Returns [m00, m01, m10, m11, tx, ty] (forward: maps source → destination).
List<double>? estimateSimilarityTransform(
  List<Offset> src,
  List<Offset> dst,
) {
  if (src.length != dst.length || src.length < 2) return null;

  final n = src.length;
  var srcMx = 0.0, srcMy = 0.0, dstMx = 0.0, dstMy = 0.0;
  for (var i = 0; i < n; i++) {
    srcMx += src[i].dx;
    srcMy += src[i].dy;
    dstMx += dst[i].dx;
    dstMy += dst[i].dy;
  }
  srcMx /= n;
  srcMy /= n;
  dstMx /= n;
  dstMy /= n;

  var a = 0.0, b = 0.0, denom = 0.0;
  for (var i = 0; i < n; i++) {
    final sx = src[i].dx - srcMx;
    final sy = src[i].dy - srcMy;
    final dx = dst[i].dx - dstMx;
    final dy = dst[i].dy - dstMy;
    a += sx * dx + sy * dy;
    b += sx * dy - sy * dx;
    denom += sx * sx + sy * sy;
  }
  if (denom < 1e-8) return null;

  final scale = math.sqrt(a * a + b * b) / denom;
  final m00 = a / denom * scale;
  final m01 = -b / denom * scale;
  final m10 = b / denom * scale;
  final m11 = a / denom * scale;
  final tx = dstMx - m00 * srcMx - m01 * srcMy;
  final ty = dstMy - m10 * srcMx - m11 * srcMy;

  return [m00, m01, m10, m11, tx, ty];
}

/// Warps [source] to [outW]×[outH] using inverse of forward similarity [m].
img.Image? warpSimilarityToSize(
  img.Image source,
  List<double> forwardM,
  int outW,
  int outH,
) {
  if (forwardM.length != 6) return null;
  final m00 = forwardM[0];
  final m01 = forwardM[1];
  final m10 = forwardM[2];
  final m11 = forwardM[3];
  final tx = forwardM[4];
  final ty = forwardM[5];

  final det = m00 * m11 - m01 * m10;
  if (det.abs() < 1e-10) return null;
  final inv00 = m11 / det;
  final inv01 = -m01 / det;
  final inv10 = -m10 / det;
  final inv11 = m00 / det;

  final out = img.Image(width: outW, height: outH);
  final sw = source.width - 1;
  final sh = source.height - 1;

  for (var v = 0; v < outH; v++) {
    for (var u = 0; u < outW; u++) {
      final dx = u.toDouble() - tx;
      final dy = v.toDouble() - ty;
      final sx = inv00 * dx + inv01 * dy;
      final sy = inv10 * dx + inv11 * dy;
      if (sx < 0 || sx > sw || sy < 0 || sy > sh) continue;
      out.setPixel(u, v, bilinearSample(source, sx, sy));
    }
  }
  return out;
}

/// Aligns face to 112×112 using 5-point (or 2-point eye) similarity warp.
img.Image? alignFaceTo112(img.Image source, Face face) {
  final src = collectFivePointLandmarks(face);
  if (src == null) return _alignEyesOnlyFallback(source, face);
  return _alignWithLandmarkPoints(source, src, face);
}

/// Aligns using landmarks from [face] after the source was mirrored horizontally.
img.Image? alignFaceTo112Mirrored(img.Image source, Face face) {
  final src = collectFivePointLandmarks(face);
  if (src == null) return null;
  final mirrored = mirrorLandmarkPoints(src, source.width);
  if (mirrored == null) return null;
  final flipped = img.flipHorizontal(source);
  return _alignWithLandmarkPoints(flipped, mirrored, face);
}

img.Image? _alignWithLandmarkPoints(
  img.Image source,
  List<Offset> src,
  Face face,
) {
  final dst = src.length == 5
      ? kFaceTemplate112
      : [kFaceTemplate112[0], kFaceTemplate112[1]];

  final m = estimateSimilarityTransform(src, dst);
  if (m == null) return _alignEyesOnlyFallback(source, face);

  final aligned = warpSimilarityToSize(source, m, 112, 112);
  if (aligned == null || _isBlank(aligned)) {
    return _alignEyesOnlyFallback(source, face);
  }
  return aligned;
}

bool _isBlank(img.Image im) {
  var samples = 0;
  var dark = 0;
  for (var y = 0; y < im.height; y += 8) {
    for (var x = 0; x < im.width; x += 8) {
      samples++;
      final p = im.getPixel(x, y);
      if (p.r < 12 && p.g < 12 && p.b < 12) dark++;
    }
  }
  return samples > 0 && dark > samples * 0.95;
}

img.Image? _alignEyesOnlyFallback(img.Image source, Face face) {
  final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
  final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
  if (leftEye == null || rightEye == null) {
    return _cropAndResizeFallback(source, face);
  }

  final src = [
    Offset(leftEye.x.toDouble(), leftEye.y.toDouble()),
    Offset(rightEye.x.toDouble(), rightEye.y.toDouble()),
  ];
  final m = estimateSimilarityTransform(src, kFaceTemplate112.sublist(0, 2));
  if (m == null) return _cropAndResizeFallback(source, face);

  final aligned = warpSimilarityToSize(source, m, 112, 112);
  if (aligned == null || _isBlank(aligned)) {
    return _cropAndResizeFallback(source, face);
  }
  return aligned;
}

img.Image? _cropAndResizeFallback(img.Image source, Face face) {
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

  final crop = img.copyCrop(
    source,
    x: left,
    y: top,
    width: right - left,
    height: bottom - top,
  );
  return img.copyResize(
    crop,
    width: 112,
    height: 112,
    interpolation: img.Interpolation.linear,
  );
}
