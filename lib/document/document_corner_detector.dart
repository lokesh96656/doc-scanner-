import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

/// Consolidated document corner/rectangle detection used by manual crop
/// and selfie+ID auto-crop flows.
class DocumentCornerDetector {
  const DocumentCornerDetector._();

  /// Normalized corners (0..1) for manual crop UI: topLeft, topRight,
  /// bottomRight, bottomLeft.
  static List<Offset>? detectNormalizedCorners({
    required RecognizedText? ocrResult,
    required img.Image decoded,
  }) {
    List<Offset>? auto01;
    if (ocrResult != null) {
      auto01 = _cornersFromOcrTextBlocks(
        ocrResult,
        decoded.width,
        decoded.height,
      );
    }
    auto01 ??= _cornersFromRefinedEdges(decoded);
    return auto01;
  }

  /// Pixel rect (left, top, right, bottom) for selfie+ID auto-crop.
  static (int, int, int, int)? detectDocumentRect({
    required RecognizedText? ocrResult,
    required img.Image decoded,
  }) {
    (int, int, int, int)? rect;
    if (ocrResult != null) {
      rect = rectFromOcrBlocksScored(
        ocrResult,
        decoded.width,
        decoded.height,
      );
    }
    rect ??= rectFromEdgeProjection(decoded);
    return rect;
  }

  static List<Offset>? _cornersFromOcrTextBlocks(
    RecognizedText result,
    int width,
    int height,
  ) {
    if (result.blocks.length < 3) return null;

    double? minX, minY, maxX, maxY;
    for (final block in result.blocks) {
      final pts = block.cornerPoints;
      if (pts.isEmpty) continue;
      for (final p in pts) {
        final x = p.x.toDouble();
        final y = p.y.toDouble();
        minX = minX == null ? x : math.min(minX, x);
        minY = minY == null ? y : math.min(minY, y);
        maxX = maxX == null ? x : math.max(maxX, x);
        maxY = maxY == null ? y : math.max(maxY, y);
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

    final padX = (maxX - minX) * 0.06;
    final padY = (maxY - minY) * 0.10;

    final left = (minX - padX).clamp(0.0, width.toDouble());
    final top = (minY - padY).clamp(0.0, height.toDouble());
    final right = (maxX + padX).clamp(0.0, width.toDouble());
    final bottom = (maxY + padY).clamp(0.0, height.toDouble());

    return buildValidatedNormalizedRect(
      left,
      top,
      right,
      bottom,
      width.toDouble(),
      height.toDouble(),
    );
  }

  static (int, int, int, int)? rectFromOcrBlocksScored(
    RecognizedText rt,
    int imgW,
    int imgH,
  ) {
    final blocks = rt.blocks;
    if (blocks.isEmpty) return null;

    final scored = <TextBlock, double>{};
    for (final b in blocks) {
      final bb = b.boundingBox;
      final area = (bb.width * bb.height).abs();
      if (area < 250) continue;
      final cx = bb.left + bb.width / 2;
      final cy = bb.top + bb.height / 2;
      final nx = cx / imgW;
      final ny = cy / imgH;

      final horizontalCenter =
          (1.0 - ((nx - 0.5).abs() * 2)).clamp(0.0, 1.0);
      final lowerBonus = ny > 0.38 ? 0.5 + (ny - 0.38) : ny * 0.5;
      scored[b] = area * (0.5 + horizontalCenter * 0.35 + lowerBonus * 0.25);
    }
    if (scored.isEmpty) return null;

    final topBlocks = scored.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final takeN = math.min(16, topBlocks.length);

    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;

    for (var i = 0; i < takeN; i++) {
      final b = topBlocks[i].key;
      final pts = b.cornerPoints;
      if (pts.isNotEmpty) {
        for (final p in pts) {
          minX = math.min(minX, p.x.toDouble());
          minY = math.min(minY, p.y.toDouble());
          maxX = math.max(maxX, p.x.toDouble());
          maxY = math.max(maxY, p.y.toDouble());
        }
      } else {
        final bb = b.boundingBox;
        minX = math.min(minX, bb.left);
        minY = math.min(minY, bb.top);
        maxX = math.max(maxX, bb.right);
        maxY = math.max(maxY, bb.bottom);
      }
    }

    if (!minX.isFinite ||
        !minY.isFinite ||
        !maxX.isFinite ||
        !maxY.isFinite) {
      return null;
    }

    final padX = (0.35 * (maxX - minX)).clamp(24.0, imgW.toDouble());
    final padY = (0.55 * (maxY - minY)).clamp(24.0, imgH.toDouble());

    var left = (minX - padX).floor();
    var right = (maxX + padX).ceil();
    var top = (minY - padY).floor();
    var bottom = (maxY + padY).ceil();

    left = left.clamp(0, imgW - 2);
    right = right.clamp(left + 1, imgW - 1);
    top = top.clamp(0, imgH - 2);
    bottom = bottom.clamp(top + 1, imgH - 1);

    final boxW = (right - left).toDouble();
    final boxH = (bottom - top).toDouble();
    final areaRatio = (boxW * boxH) / (imgW * imgH);
    final aspect = boxW / boxH;

    if (areaRatio < 0.04 || areaRatio > 0.92) return null;
    if (aspect < 0.6 || aspect > 3.2) return null;

    return (left, top, right, bottom);
  }

  static List<Offset>? _cornersFromRefinedEdges(img.Image decoded) {
    const targetW = 640;
    final resized = decoded.width > targetW
        ? img.copyResize(decoded, width: targetW)
        : decoded;

    final gray = img.grayscale(resized);
    final w = gray.width;
    final h = gray.height;
    if (w < 20 || h < 20) return null;

    final lumBox = _coarseBoxFromLuminance(gray);
    final edgeBox = lumBox ?? _coarseBoxFromEdgeHull(gray);

    if (edgeBox == null) return null;

    var left = edgeBox.$1;
    var top = edgeBox.$2;
    var right = edgeBox.$3;
    var bottom = edgeBox.$4;

    if (right <= left || bottom <= top) return null;

    final refined = _refineBoxByLocalEdges(gray, left, top, right, bottom);
    left = refined.$1;
    top = refined.$2;
    right = refined.$3;
    bottom = refined.$4;

    if (right <= left || bottom <= top) return null;

    final scaleX = decoded.width / w;
    final scaleY = decoded.height / h;
    final l = left * scaleX;
    final t = top * scaleY;
    final r = right * scaleX;
    final b = bottom * scaleY;

    return buildValidatedNormalizedRect(
      l,
      t,
      r,
      b,
      decoded.width.toDouble(),
      decoded.height.toDouble(),
    );
  }

  static (int, int, int, int)? rectFromEdgeProjection(img.Image original) {
    final targetW = 360;
    final scale = targetW / original.width;
    final small = img.copyResize(
      original,
      width: targetW,
      height: (original.height * scale).round().clamp(1, 5000),
      interpolation: img.Interpolation.linear,
    );

    final w = small.width;
    final h = small.height;

    final gray = img.grayscale(small);
    final rowEdge = List<double>.filled(h, 0);
    final colEdge = List<double>.filled(w, 0);

    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final dx = (gray.getPixel(x + 1, y).r.toDouble() -
                gray.getPixel(x - 1, y).r.toDouble())
            .abs();
        final dy = (gray.getPixel(x, y + 1).r.toDouble() -
                gray.getPixel(x, y - 1).r.toDouble())
            .abs();
        final cx = (x - w / 2).abs() / (w / 2);
        final cy = (y - h / 2).abs() / (h / 2);
        final weight = 1.0 - (0.25 * (cx + cy)).clamp(0.0, 0.5);
        final e = (dx + dy) * weight;

        rowEdge[y] += e;
        colEdge[x] += e;
      }
    }

    int argMax(List<double> v) {
      var bestI = 0;
      var best = -1.0;
      for (var i = 0; i < v.length; i++) {
        if (v[i] > best) {
          best = v[i];
          bestI = i;
        }
      }
      return bestI;
    }

    var top = argMax(rowEdge.sublist(0, (h * 0.6).round().clamp(2, h)));
    var bottom = argMax(rowEdge
            .sublist((h * 0.4).round().clamp(0, h - 2), h - 1)) +
        (h * 0.4).round().clamp(0, h - 2);
    var left = argMax(colEdge.sublist(0, (w * 0.6).round().clamp(2, w)));
    var right = argMax(colEdge
            .sublist((w * 0.4).round().clamp(0, w - 2), w - 1)) +
        (w * 0.4).round().clamp(0, w - 2);

    final padX = (0.03 * w).round();
    final padY = (0.03 * h).round();
    left = (left - padX).clamp(0, w - 2);
    right = (right + padX).clamp(left + 1, w - 1);
    top = (top - padY).clamp(0, h - 2);
    bottom = (bottom + padY).clamp(top + 1, h - 1);

    final boxW = (right - left).toDouble();
    final boxH = (bottom - top).toDouble();
    if (boxW <= 0 || boxH <= 0) return null;

    final areaRatio = (boxW * boxH) / (w * h);
    final aspect = boxW / boxH;
    if (areaRatio < 0.08 || areaRatio > 0.92) return null;
    if (aspect < 0.6 || aspect > 3.2) return null;

    final inv = 1 / scale;
    final oLeft = (left * inv).round().clamp(0, original.width - 2);
    final oRight = (right * inv).round().clamp(oLeft + 1, original.width - 1);
    final oTop = (top * inv).round().clamp(0, original.height - 2);
    final oBottom =
        (bottom * inv).round().clamp(oTop + 1, original.height - 1);

    return (oLeft, oTop, oRight, oBottom);
  }

  static List<Offset>? buildValidatedNormalizedRect(
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

  static (int, int, int, int)? _coarseBoxFromLuminance(img.Image gray) {
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

    const m = 0.03;
    final mx = ((right - left) * m).round().clamp(2, 24);
    final my = ((bottom - top) * m).round().clamp(2, 24);
    return (
      (left - mx).clamp(0, w - 2),
      (top - my).clamp(0, h - 2),
      (right + mx).clamp(2, w - 1),
      (bottom + my).clamp(2, h - 1),
    );
  }

  static (int, int, int, int)? _coarseBoxFromEdgeHull(img.Image gray) {
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

  static (int, int, int, int) _refineBoxByLocalEdges(
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
        s += (gray.getPixel(x, y).r - gray.getPixel(x, y - 1).r)
            .abs()
            .toDouble();
      }
      return s;
    }

    double vertStrength(int x) {
      if (x <= 0 || x >= w - 1) return 0;
      var s = 0.0;
      for (var y = y0; y < y1; y++) {
        s += (gray.getPixel(x, y).r - gray.getPixel(x - 1, y).r)
            .abs()
            .toDouble();
      }
      return s;
    }

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
}
