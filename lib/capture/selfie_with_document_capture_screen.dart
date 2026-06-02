import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Front-camera capture where user holds the ID next to their face.
/// Returns a single image path containing both face + document.
class SelfieWithDocumentCaptureScreen extends StatefulWidget {
  const SelfieWithDocumentCaptureScreen({super.key});

  @override
  State<SelfieWithDocumentCaptureScreen> createState() =>
      SelfieWithDocumentCaptureScreenState();
}

class SelfieWithDocumentCaptureScreenState
    extends State<SelfieWithDocumentCaptureScreen> {
  CameraController? _controller;
  bool _isInitializing = true;
  bool _isCapturing = false;
  String? _previewPath;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        front,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _isInitializing = false;
      });
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pop<String?>(null);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);
    try {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      final file = await c.takePicture();
      if (!mounted) return;
      setState(() {
        _previewPath = file.path;
        _isCapturing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isCapturing = false);
    }
  }

  void _retake() {
    setState(() => _previewPath = null);
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final preview = _previewPath;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop<String?>(null),
        ),
        title: Text(preview == null ? 'Selfie with ID' : 'Review'),
      ),
      body: _isInitializing || c == null
          ? const Center(child: CircularProgressIndicator())
          : preview != null
              ? Column(
                  children: [
                    Expanded(
                      child: Image.file(File(preview), fit: BoxFit.contain),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton(
                            onPressed: () => Navigator.of(context).pop(preview),
                            child: const Text('Use this photo'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _retake,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retake'),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned.fill(child: CameraPreview(c)),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: SelfieWithDocumentOverlayPainter(
                                  color: Colors.white.withValues(alpha: 0.9),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Material(
                      elevation: 8,
                      color: Theme.of(context).colorScheme.surface,
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Face in oval · ID in box below',
                                style: Theme.of(context).textTheme.bodyMedium,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: _isCapturing ? null : _capture,
                                icon: const Icon(Icons.camera_alt),
                                label: Text(
                                  _isCapturing ? 'Capturing…' : 'Capture photo',
                                ),
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(56),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class SelfieWithDocumentOverlayPainter extends CustomPainter {
  SelfieWithDocumentOverlayPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final labelStyle = TextStyle(
      color: color,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );

    // Place the face guide around the real face area (centered), not too high.
    const gap = 0.08;
    final faceW = size.width * 0.52;
    final faceH = size.height * 0.38;
    final faceCenterY = size.height * 0.32;

    final faceRect = Rect.fromCenter(
      center: Offset(size.width / 2, faceCenterY),
      width: faceW,
      height: faceH,
    );
    canvas.drawOval(faceRect, paint);
    _drawLabel(canvas, 'Face', faceRect.topCenter, labelStyle);

    // Keep the ID box clearly below the face, but not too close to the bottom bar.
    final docW = size.width * 0.84;
    final docH = size.height * 0.18;
    var docCenterY = faceRect.bottom + size.height * gap + docH / 2;
    docCenterY = math.max(docCenterY, size.height * 0.62);
    docCenterY = math.min(docCenterY, size.height * 0.82);

    final docRect = Rect.fromCenter(
      center: Offset(
        size.width / 2,
        docCenterY.clamp(docH / 2, size.height - docH / 2),
      ),
      width: docW,
      height: docH,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(docRect, const Radius.circular(14)),
      paint,
    );
    _drawLabel(canvas, 'ID card', docRect.topCenter, labelStyle);
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset anchor,
    TextStyle style,
  ) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(anchor.dx - tp.width / 2, anchor.dy - tp.height - 6),
    );
  }

  @override
  bool shouldRepaint(covariant SelfieWithDocumentOverlayPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
