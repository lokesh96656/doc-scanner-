import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class SelfieCaptureScreen extends StatefulWidget {
  const SelfieCaptureScreen({super.key});

  @override
  State<SelfieCaptureScreen> createState() => SelfieCaptureScreenState();
}

class SelfieCaptureScreenState extends State<SelfieCaptureScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  CameraLensDirection _lensDirection = CameraLensDirection.front;
  bool _isInitializing = true;
  bool _isCapturing = false;
  bool _isSwitchingCamera = false;
  String? _previewPath;

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

      await _controller?.dispose();
      final controller = CameraController(
        selected,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _lensDirection = selected.lensDirection;
        _isInitializing = false;
        _isSwitchingCamera = false;
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
    if (_isCapturing || _isInitializing || _isSwitchingCamera || !_canSwitchCamera) {
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

  String get _captureHint {
    if (_lensDirection == CameraLensDirection.back) {
      return 'Back camera: face the camera. Only one person should be visible.';
    }
    return 'Look at the camera. Only your face should be visible.';
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
        title: Text(preview == null ? 'Take selfie' : 'Review selfie'),
        actions: [
          if (preview == null && _canSwitchCamera)
            IconButton(
              tooltip: _lensDirection == CameraLensDirection.front
                  ? 'Use back camera'
                  : 'Use front camera',
              onPressed: busy ? null : _toggleCamera,
              icon: const Icon(Icons.cameraswitch),
            ),
        ],
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
                            child: const Text('Use this selfie'),
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
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _captureHint,
                              style: const TextStyle(color: Colors.white),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _isCapturing ? null : _capture,
                            icon: const Icon(Icons.face),
                            label: Text(
                              _isCapturing ? 'Capturing…' : 'Capture selfie',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}
