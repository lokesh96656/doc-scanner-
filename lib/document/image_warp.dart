import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

double offsetDistance(Offset a, Offset b) {
  return math.sqrt(
    (a.dx - b.dx) * (a.dx - b.dx) + (a.dy - b.dy) * (a.dy - b.dy),
  );
}

/// Warps source image so quad (topLeft, topRight, bottomRight, bottomLeft)
/// becomes a straight rectangle.
img.Image? perspectiveWarp(
  img.Image src,
  List<Offset> quad,
  int outW,
  int outH,
) {
  if (quad.length != 4) return null;
  final x0 = quad[0].dx;
  final y0 = quad[0].dy;
  final x1 = quad[1].dx;
  final y1 = quad[1].dy;
  final x2 = quad[2].dx;
  final y2 = quad[2].dy;
  final x3 = quad[3].dx;
  final y3 = quad[3].dy;
  final w = outW.toDouble();
  final h = outH.toDouble();

  final a = <List<double>>[
    [0, 0, 1, 0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0, 1, 0, 0],
    [w, 0, 1, 0, 0, 0, -x1 * w, -x1 * 0],
    [0, 0, 0, w, 0, 1, -y1 * w, -y1 * 0],
    [w, h, 1, 0, 0, 0, -x2 * w, -x2 * h],
    [0, 0, 0, w, h, 1, -y2 * w, -y2 * h],
    [0, h, 1, 0, 0, 0, -x3 * 0, -x3 * h],
    [0, 0, 0, 0, h, 1, -y3 * 0, -y3 * h],
  ];
  final b = [x0, y0, x1, y1, x2, y2, x3, y3];
  final hCoeffs = solveLinearSystem8(a, b);
  if (hCoeffs == null) return null;

  final out = img.Image(width: outW, height: outH);
  final sw = src.width - 1;
  final sh = src.height - 1;
  for (var v = 0; v < outH; v++) {
    for (var u = 0; u < outW; u++) {
      final uu = u.toDouble();
      final vv = v.toDouble();
      final den = hCoeffs[6] * uu + hCoeffs[7] * vv + 1;
      if (den.abs() < 1e-10) continue;
      final x = (hCoeffs[0] * uu + hCoeffs[1] * vv + hCoeffs[2]) / den;
      final y = (hCoeffs[3] * uu + hCoeffs[4] * vv + hCoeffs[5]) / den;
      if (x < 0 || x > sw || y < 0 || y > sh) continue;
      final px = bilinearSample(src, x, y);
      out.setPixel(u, v, px);
    }
  }
  return out;
}

List<double>? solveLinearSystem8(List<List<double>> a, List<double> b) {
  const n = 8;
  final matrix = List.generate(n, (i) => List<double>.from(a[i])..add(b[i]));
  for (var col = 0; col < n; col++) {
    var maxRow = col;
    for (var row = col + 1; row < n; row++) {
      if (matrix[row][col].abs() > matrix[maxRow][col].abs()) maxRow = row;
    }
    final tmp = matrix[col];
    matrix[col] = matrix[maxRow];
    matrix[maxRow] = tmp;
    if (matrix[col][col].abs() < 1e-12) return null;
    final pivot = matrix[col][col];
    for (var j = 0; j <= n; j++) {
      matrix[col][j] /= pivot;
    }
    for (var row = 0; row < n; row++) {
      if (row == col) continue;
      final f = matrix[row][col];
      for (var j = 0; j <= n; j++) {
        matrix[row][j] -= f * matrix[col][j];
      }
    }
  }
  return List.generate(n, (i) => matrix[i][n]);
}

img.Color bilinearSample(img.Image src, double x, double y) {
  final x0 = x.floor().clamp(0, src.width - 1);
  final y0 = y.floor().clamp(0, src.height - 1);
  final x1 = (x0 + 1).clamp(0, src.width - 1);
  final y1 = (y0 + 1).clamp(0, src.height - 1);
  final fx = x - x0;
  final fy = y - y0;
  final p00 = src.getPixel(x0, y0);
  final p10 = src.getPixel(x1, y0);
  final p01 = src.getPixel(x0, y1);
  final p11 = src.getPixel(x1, y1);
  final r =
      (p00.r * (1 - fx) * (1 - fy) +
              p10.r * fx * (1 - fy) +
              p01.r * (1 - fx) * fy +
              p11.r * fx * fy)
          .round()
          .clamp(0, 255);
  final g =
      (p00.g * (1 - fx) * (1 - fy) +
              p10.g * fx * (1 - fy) +
              p01.g * (1 - fx) * fy +
              p11.g * fx * fy)
          .round()
          .clamp(0, 255);
  final b =
      (p00.b * (1 - fx) * (1 - fy) +
              p10.b * fx * (1 - fy) +
              p01.b * (1 - fx) * fy +
              p11.b * fx * fy)
          .round()
          .clamp(0, 255);
  final a =
      (p00.a * (1 - fx) * (1 - fy) +
              p10.a * fx * (1 - fy) +
              p01.a * (1 - fx) * fy +
              p11.a * fx * fy)
          .round()
          .clamp(0, 255);
  return img.ColorRgba8(r, g, b, a);
}
