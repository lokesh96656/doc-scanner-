import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../document/document_corner_detector.dart';
import '../document/image_warp.dart';
import '../document/tilt_detection.dart';
import '../face/face_image_utils.dart';
import 'crop_screen_result.dart';
import 'quad_overlay_painter.dart';

class CropDocumentScreen extends StatefulWidget {
  const CropDocumentScreen({super.key, required this.imagePath});

  final String imagePath;

  @override
  State<CropDocumentScreen> createState() => CropDocumentScreenState();
}

class CropDocumentScreenState extends State<CropDocumentScreen> {
  List<Offset>? _corners;
  List<Offset>? _autoCorners01;
  Size? _viewSize;
  bool _hasUserAdjustedCorners = false;
  img.Image? _orientedImage;
  Uint8List? _previewBytes;

  static const double _handleSize = 20;
  static const double _cornerCenterInset = 26;
  static const double _touchTarget = 48;

  double _draggableInset(double width, double height) {
    final m = math.min(width, height) / 2 - 2;
    return _cornerCenterInset.clamp(0.0, m > 0 ? m : 0.0);
  }

  void _applySafeCornerInsets(double width, double height) {
    if (_corners == null) return;
    final p = _draggableInset(width, height);
    for (var i = 0; i < 4; i++) {
      _corners![i] = Offset(
        _corners![i].dx.clamp(p, width - p),
        _corners![i].dy.clamp(p, height - p),
      );
    }
  }

  void _initCorners(double width, double height) {
    const margin = 0.1;
    if (_corners != null) return;

    if (_autoCorners01 != null && _autoCorners01!.length == 4) {
      _corners = _autoCorners01!
          .map((p) => Offset(p.dx * width, p.dy * height))
          .toList(growable: false);
    } else {
      _corners = [
        Offset(width * margin, height * margin),
        Offset(width * (1 - margin), height * margin),
        Offset(width * (1 - margin), height * (1 - margin)),
        Offset(width * margin, height * (1 - margin)),
      ];
    }

    _applySafeCornerInsets(width, height);
  }

  @override
  void initState() {
    super.initState();
    _loadOrientedImage();
  }

  Future<void> _loadOrientedImage() async {
    final oriented = loadOrientedImage(widget.imagePath);
    if (oriented == null || !mounted) return;
    setState(() {
      _orientedImage = oriented;
      _previewBytes = Uint8List.fromList(img.encodeJpg(oriented, quality: 90));
    });
    await _detectAutoCorners(oriented);
  }

  Future<void> _detectAutoCorners(img.Image decoded) async {
    try {
      final inputImage = InputImage.fromFilePath(widget.imagePath);
      final recognizer = TextRecognizer();
      final result = await recognizer.processImage(inputImage);
      recognizer.close();

      final auto01 = DocumentCornerDetector.detectNormalizedCorners(
        ocrResult: result,
        decoded: decoded,
      );
      if (auto01 == null) return;

      if (!mounted) return;
      setState(() {
        _autoCorners01 = auto01;
        if (!_hasUserAdjustedCorners && _viewSize != null) {
          _corners = auto01
              .map(
                (p) =>
                    Offset(p.dx * _viewSize!.width, p.dy * _viewSize!.height),
              )
              .toList(growable: false);
          _applySafeCornerInsets(_viewSize!.width, _viewSize!.height);
        }
      });
    } catch (_) {
      // Ignore: fall back to default corners.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop<CropScreenResult?>(null),
        ),
        title: const Text('Match card corners'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context)
                .pop(const CropScreenResult(retakePhoto: true)),
            child: const Text('Retake photo'),
          ),
          TextButton(
            onPressed: () async {
              if (_viewSize == null || _corners == null) {
                Navigator.of(context).pop<CropScreenResult?>(null);
                return;
              }
              final cropped = await _cropAndEnhance();
              if (!context.mounted) return;
              if (cropped == null) {
                Navigator.of(context).pop<CropScreenResult?>(null);
                return;
              }
              Navigator.of(context)
                  .pop(CropScreenResult(croppedFile: cropped));
            },
            child: const Text('Done'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final height = constraints.maxHeight;
                _viewSize ??= Size(width, height);
                _initCorners(width, height);
                _applySafeCornerInsets(width, height);
                final corners = _corners!;

                return Stack(
                  children: [
                    Positioned.fill(
                      child: _previewBytes == null
                          ? const Center(child: CircularProgressIndicator())
                          : Image.memory(
                              _previewBytes!,
                              fit: BoxFit.fill,
                            ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: QuadOverlayPainter(corners: corners),
                        ),
                      ),
                    ),
                    _buildHandle(corners[0], (delta) => _moveCorner(0, delta)),
                    _buildHandle(corners[1], (delta) => _moveCorner(1, delta)),
                    _buildHandle(corners[2], (delta) => _moveCorner(2, delta)),
                    _buildHandle(corners[3], (delta) => _moveCorner(3, delta)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _moveCorner(int index, Offset delta) {
    final size = _viewSize!;
    final p = _draggableInset(size.width, size.height);
    setState(() {
      _hasUserAdjustedCorners = true;
      final c = _corners![index];
      _corners![index] = Offset(
        (c.dx + delta.dx).clamp(p, size.width - p),
        (c.dy + delta.dy).clamp(p, size.height - p),
      );
    });
  }

  Widget _buildHandle(Offset position, void Function(Offset delta) onDrag) {
    return Positioned(
      left: position.dx - _touchTarget / 2,
      top: position.dy - _touchTarget / 2,
      child: GestureDetector(
        dragStartBehavior: DragStartBehavior.down,
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          onDrag(details.delta);
        },
        child: SizedBox(
          width: _touchTarget,
          height: _touchTarget,
          child: Center(
            child: Container(
              width: _handleSize,
              height: _handleSize,
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.blue, width: 2),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<File?> _cropAndEnhance() async {
    final corners = _corners!;
    final size = _viewSize!;
    final original = _orientedImage;
    if (original == null) return null;

    final scaleX = original.width / size.width;
    final scaleY = original.height / size.height;

    final srcQuad = corners
        .map((o) => Offset(o.dx * scaleX, o.dy * scaleY))
        .toList();

    final w1 = offsetDistance(srcQuad[0], srcQuad[1]);
    final w2 = offsetDistance(srcQuad[3], srcQuad[2]);
    final h1 = offsetDistance(srcQuad[0], srcQuad[3]);
    final h2 = offsetDistance(srcQuad[1], srcQuad[2]);
    const maxSide = 640;
    var outW = (math.max(w1, w2)).round().clamp(1, original.width);
    var outH = (math.max(h1, h2)).round().clamp(1, original.height);
    if (outW > maxSide || outH > maxSide) {
      if (outW >= outH) {
        outH = (outH * maxSide / outW).round().clamp(1, original.height);
        outW = maxSide;
      } else {
        outW = (outW * maxSide / outH).round().clamp(1, original.width);
        outH = maxSide;
      }
    }

    img.Image? work = perspectiveWarp(original, srcQuad, outW, outH);
    if (work == null) return null;

    final tiltAngle = await detectTiltAngle(work);
    if (tiltAngle.abs() > 1.2) {
      work = img.copyRotate(work, angle: -tiltAngle);
    }

    // Keep original color for face matching — contrast boost hurts embeddings.
    final dir = await getTemporaryDirectory();
    final outPath =
        '${dir.path}/scan_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final outFile = File(outPath);
    await outFile.writeAsBytes(img.encodeJpg(work, quality: 92));
    return outFile;
  }
}
