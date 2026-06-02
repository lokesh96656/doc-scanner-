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
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _isInitializing = false;
      });
    } catch (e) {
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
        title: Text(preview == null ? 'Take selfie' : 'Review selfie'),
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
                            child: const Text(
                              'Look at the camera. Only your face should be visible.',
                              style: TextStyle(color: Colors.white),
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
