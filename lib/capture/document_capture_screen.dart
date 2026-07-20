import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class DocumentCaptureScreen extends StatefulWidget {
  const DocumentCaptureScreen({super.key});

  @override
  State<DocumentCaptureScreen> createState() => DocumentCaptureScreenState();
}

class DocumentCaptureScreenState extends State<DocumentCaptureScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  CameraLensDirection _lensDirection = CameraLensDirection.back;
  bool _isInitializing = true;
  bool _isCapturing = false;
  bool _isSwitchingCamera = false;
  String? _previewPath;

  List<int>? _prevLuma;
  int _stableFrames = 0;

  static const int _sampleW = 64;
  static const int _sampleH = 48;
  static const int _neededStableFrames = 12;
  static const double _diffThreshold = 6.0;
  static const double _sharpnessThreshold = 12.0;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  bool get _canSwitchCamera =>
      _cameras.any((c) => c.lensDirection == CameraLensDirection.front) &&
      _cameras.any((c) => c.lensDirection == CameraLensDirection.back);

  Future<void> _initCamera({CameraLensDirection? prefer}) async {
    final target = prefer ?? _lensDirection;
    if (mounted) {
      setState(() => _isInitializing = true);
    }
    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }
      final selected = _cameras.firstWhere(
        (c) => c.lensDirection == target,
        orElse: () => _cameras.first,
      );

      final old = _controller;
      _controller = null;
      if (old != null) {
        try {
          await old.stopImageStream();
        } catch (_) {}
        await old.dispose();
      }

      final controller = CameraController(
        selected,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      await controller.startImageStream(_onFrame);
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _lensDirection = selected.lensDirection;
        _isInitializing = false;
        _isSwitchingCamera = false;
        _stableFrames = 0;
        _prevLuma = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (_controller == null) {
        Navigator.of(context).pop<String?>(null);
        return;
      }
      setState(() {
        _isInitializing = false;
        _isSwitchingCamera = false;
      });
    }
  }

  Future<void> _toggleCamera() async {
    if (_isCapturing ||
        _isInitializing ||
        _isSwitchingCamera ||
        _previewPath != null ||
        !_canSwitchCamera) {
      return;
    }
    setState(() => _isSwitchingCamera = true);
    final next = _lensDirection == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front;
    await _initCamera(prefer: next);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onFrame(CameraImage image) {
    if (_isCapturing || _isSwitchingCamera || _previewPath != null) return;
    final plane = image.planes.first;
    final bytes = plane.bytes;
    final rowStride = plane.bytesPerRow;

    final sample = List<int>.filled(_sampleW * _sampleH, 0);
    final stepX = (image.width / _sampleW).floor().clamp(1, image.width);
    final stepY = (image.height / _sampleH).floor().clamp(1, image.height);

    var idx = 0;
    for (var sy = 0; sy < _sampleH; sy++) {
      final y = (sy * stepY).clamp(0, image.height - 1);
      final rowOff = y * rowStride;
      for (var sx = 0; sx < _sampleW; sx++) {
        final x = (sx * stepX).clamp(0, image.width - 1);
        sample[idx++] = bytes[rowOff + x];
      }
    }

    final sharp = _estimateSharpness(sample);
    final diff = _prevLuma == null ? 999.0 : _meanAbsDiff(_prevLuma!, sample);
    _prevLuma = sample;

    final stable = diff < _diffThreshold && sharp > _sharpnessThreshold;
    _stableFrames = stable ? (_stableFrames + 1) : 0;

    if (_stableFrames >= _neededStableFrames) {
      _capture();
    } else {
      if (mounted) setState(() {});
    }
  }

  double _meanAbsDiff(List<int> a, List<int> b) {
    var sum = 0;
    for (var i = 0; i < a.length; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return sum / a.length;
  }

  double _estimateSharpness(List<int> luma) {
    double sum = 0;
    int count = 0;
    for (var y = 0; y < _sampleH - 1; y++) {
      for (var x = 0; x < _sampleW - 1; x++) {
        final i = y * _sampleW + x;
        final gx = (luma[i + 1] - luma[i]).abs();
        final gy = (luma[i + _sampleW] - luma[i]).abs();
        sum += gx + gy;
        count++;
      }
    }
    return count == 0 ? 0 : sum / count;
  }

  Future<void> _capture() async {
    if (_isCapturing || _previewPath != null) return;
    setState(() => _isCapturing = true);
    try {
      final c = _controller;
      if (c == null) return;
      try {
        await c.stopImageStream();
      } catch (_) {}
      final file = await c.takePicture();
      if (!mounted) return;
      setState(() {
        _previewPath = file.path;
        _isCapturing = false;
        _stableFrames = 0;
        _prevLuma = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isCapturing = false);
    }
  }

  Future<void> _retake() async {
    setState(() {
      _previewPath = null;
      _stableFrames = 0;
      _prevLuma = null;
    });
    final c = _controller;
    if (c != null && c.value.isInitialized) {
      try {
        await c.startImageStream(_onFrame);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final preview = _previewPath;
    final busy = _isInitializing || _isSwitchingCamera;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop<String?>(null),
        ),
        title: Text(preview == null ? 'Scan document' : 'Review document'),
        actions: preview == null
            ? [
                if (_canSwitchCamera)
                  IconButton(
                    tooltip: _lensDirection == CameraLensDirection.front
                        ? 'Use back camera'
                        : 'Use front camera',
                    onPressed: busy ? null : _toggleCamera,
                    icon: const Icon(Icons.cameraswitch),
                  ),
                TextButton(
                  onPressed: (_isCapturing || busy) ? null : _capture,
                  child: const Text('Capture now'),
                ),
              ]
            : null,
      ),
      body: busy || c == null
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
              : Stack(
                  children: [
                    Positioned.fill(child: CameraPreview(c)),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          child: Text(
                            _lensDirection == CameraLensDirection.front
                                ? 'Front camera'
                                : 'Back camera',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 24,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: DefaultTextStyle(
                          style: const TextStyle(color: Colors.white),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _isCapturing
                                    ? 'Capturing...'
                                    : (_stableFrames >= _neededStableFrames
                                        ? 'Captured'
                                        : 'Hold steady…'),
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
