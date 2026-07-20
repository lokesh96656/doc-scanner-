import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../capture/document_capture_screen.dart';
import '../capture/selfie_capture_screen.dart';
import '../capture/selfie_with_document_capture_screen.dart';
import '../crop/crop_document_screen.dart';
import '../crop/crop_screen_result.dart';
import '../document/document_auto_crop.dart';
import '../face/aws_rekognition_face_service.dart';
import '../face/face_match_service.dart';
import '../face/face_preview_crop.dart';
import '../ocr/json_template_engine.dart';
import '../scan/scan_flow_mode.dart';
import '../utils/string_similarity.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.title});

  final String title;

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  final TextRecognizer _textRecognizer = TextRecognizer();
  final FaceMatchService _faceMatchService = FaceMatchService();
  final AwsRekognitionFaceService _awsFaceMatchService =
      AwsRekognitionFaceService();
  final TextEditingController _documentNumberController =
      TextEditingController();

  String _recognizedText = '';
  bool _isProcessing = false;
  String _processingMessage = '';
  XFile? _imageFile;
  XFile? _selfieFile;
  XFile? _selfieWithDocFile;
  String? _detectedDocumentNumber;
  double? _matchPercent;
  bool? _isDocumentNumberMatch;

  double? _faceMatchPercent;
  bool? _isFaceMatchPass;
  String? _faceMatchError;
  bool _faceUsedEmbeddingModel = false;
  String? _faceMatchProvider;

  ScanFlowMode? _flowMode;

  Map<String, String> _extractedFields = const {};
  String _detectedTemplateText = 'Unknown';
  JsonTemplateEngine? _jsonTemplates;
  bool _jsonLoading = false;
  String? _pendingOcrForJson;

  @override
  void initState() {
    super.initState();
    _loadJsonTemplates();
  }

  @override
  void dispose() {
    _documentNumberController.dispose();
    _textRecognizer.close();
    _faceMatchService.dispose();
    _awsFaceMatchService.dispose();
    super.dispose();
  }

  Future<void> _loadJsonTemplates() async {
    if (_jsonTemplates != null || _jsonLoading) return;
    _jsonLoading = true;
    try {
      final engine = await JsonTemplateEngine.loadFromAssets();
      if (!mounted) return;
      setState(() => _jsonTemplates = engine);
      final pending = _pendingOcrForJson;
      if (pending != null) {
        _pendingOcrForJson = null;
        _runTemplatePipeline(pending);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _detectedTemplateText = 'Template load failed');
    } finally {
      _jsonLoading = false;
    }
  }

  String? _pickDocumentNumberFromFields(Map<String, String> fields) {
    const keysByPriority = <String>[
      'PAN',
      'Aadhaar',
      'DL No',
      'Licence No',
      'Passport No',
      'Document No',
    ];
    for (final k in keysByPriority) {
      final v = fields[k];
      if (v != null && v.trim().isNotEmpty) {
        return v.trim();
      }
    }
    return null;
  }

  void _updateDocumentNumberMatch() {
    final expected = _documentNumberController.text.trim();
    final detected = _detectedDocumentNumber?.trim() ?? '';

    if (expected.isEmpty || detected.isEmpty) {
      setState(() {
        _matchPercent = null;
        _isDocumentNumberMatch = null;
      });
      return;
    }

    final similarity = calculateStringSimilarity(
      expected.toLowerCase(),
      detected.toLowerCase(),
    );

    setState(() {
      _matchPercent = similarity * 100;
      _isDocumentNumberMatch = similarity >= 0.8;
    });
  }

  Future<String?> _captureDocumentPhoto() async {
    return Navigator.of(context).push<String?>(
      MaterialPageRoute(builder: (_) => const DocumentCaptureScreen()),
    );
  }

  Future<File?> _cropDocumentPhoto(String rawPath) async {
    while (mounted) {
      final result = await Navigator.of(context).push<CropScreenResult?>(
        MaterialPageRoute(
          builder: (_) => CropDocumentScreen(imagePath: rawPath),
        ),
      );
      if (!mounted) return null;
      if (result == null) return null;
      if (result.retakePhoto) {
        final again = await _captureDocumentPhoto();
        if (!mounted) return null;
        if (again == null) return null;
        rawPath = again;
        continue;
      }
      return result.croppedFile;
    }
    return null;
  }

  Future<String?> _captureSelfiePhoto() async {
    return Navigator.of(context).push<String?>(
      MaterialPageRoute(builder: (_) => const SelfieCaptureScreen()),
    );
  }

  void _resetScanResults() {
    setState(() {
      _recognizedText = '';
      _detectedDocumentNumber = null;
      _matchPercent = null;
      _isDocumentNumberMatch = null;
      _faceMatchPercent = null;
      _isFaceMatchPass = null;
      _faceMatchError = null;
      _faceUsedEmbeddingModel = false;
      _faceMatchProvider = null;
    });
  }

  void _applyFaceMatchResult(FaceMatchResult faceResult) {
    setState(() {
      _faceMatchPercent = faceResult.matchPercent;
      _isFaceMatchPass = faceResult.pass;
      _faceMatchError = faceResult.error;
      _faceUsedEmbeddingModel = faceResult.usedEmbeddingModel;
      _faceMatchProvider = faceResult.provider;
    });
  }

  Future<void> _processCapturedImages({
    required String idPath,
    required String selfiePath,
  }) async {
    setState(() {
      _isProcessing = true;
      _processingMessage = 'Running OCR and face match…';
      _imageFile = XFile(idPath);
      _selfieFile = XFile(selfiePath);
    });

    try {
      final results = await Future.wait<Object?>([
        _textRecognizer.processImage(InputImage.fromFilePath(idPath)),
        _faceMatchService.compare(
          idImagePath: idPath,
          selfieImagePath: selfiePath,
        ),
      ]);

      if (!mounted) return;

      final recognizedText = results[0] as RecognizedText;
      final faceResult = results[1] as FaceMatchResult;

      setState(() {
        _recognizedText = recognizedText.text;
        _isProcessing = false;
        _processingMessage = '';
      });
      _applyFaceMatchResult(faceResult);
      _runTemplatePipeline(recognizedText.text);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _processingMessage = '';
        _recognizedText = 'Error: $e';
      });
    }
  }

  Future<void> _processCapturedImagesWithAws({
    required String idPath,
    required String selfiePath,
  }) async {
    setState(() {
      _isProcessing = true;
      _processingMessage = 'Running OCR and AWS Rekognition…';
      _imageFile = XFile(idPath);
      _selfieFile = XFile(selfiePath);
    });

    try {
      final results = await Future.wait<Object?>([
        _textRecognizer.processImage(InputImage.fromFilePath(idPath)),
        _awsFaceMatchService.compare(
          idImagePath: idPath,
          selfieImagePath: selfiePath,
        ),
      ]);

      if (!mounted) return;

      final recognizedText = results[0] as RecognizedText;
      final faceResult = results[1] as FaceMatchResult;

      setState(() {
        _recognizedText = recognizedText.text;
        _isProcessing = false;
        _processingMessage = '';
      });
      _applyFaceMatchResult(faceResult);
      _runTemplatePipeline(recognizedText.text);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _processingMessage = '';
        _recognizedText = 'Error: $e';
      });
    }
  }

  Future<void> _scanDocument() async {
    try {
      _flowMode = ScanFlowMode.twoStep;
      final rawPath = await _captureDocumentPhoto();
      if (!mounted || rawPath == null) return;

      final croppedFile = await _cropDocumentPhoto(rawPath);
      if (!mounted || croppedFile == null) return;

      final selfiePath = await _captureSelfiePhoto();
      if (!mounted || selfiePath == null) return;

      _resetScanResults();

      await _processCapturedImages(
        idPath: croppedFile.path,
        selfiePath: selfiePath,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _processingMessage = '';
        _recognizedText = 'Error: $e';
      });
    }
  }

  Future<void> _scanDocumentWithAws() async {
    try {
      _flowMode = ScanFlowMode.awsRekognition;
      final rawPath = await _captureDocumentPhoto();
      if (!mounted || rawPath == null) return;

      final croppedFile = await _cropDocumentPhoto(rawPath);
      if (!mounted || croppedFile == null) return;

      final selfiePath = await _captureSelfiePhoto();
      if (!mounted || selfiePath == null) return;

      _resetScanResults();

      await _processCapturedImagesWithAws(
        idPath: croppedFile.path,
        selfiePath: selfiePath,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _processingMessage = '';
        _recognizedText = 'Error: $e';
      });
    }
  }

  Future<void> _scanSelfieWithDocument() async {
    try {
      _flowMode = ScanFlowMode.selfieWithDocument;

      final combinedPath = await Navigator.of(context).push<String?>(
        MaterialPageRoute(
          builder: (_) => const SelfieWithDocumentCaptureScreen(),
        ),
      );
      if (!mounted || combinedPath == null) return;

      final croppedDoc = await DocumentAutoCrop.cropFromPhoto(
        imagePath: combinedPath,
        textRecognizer: _textRecognizer,
      );
      if (!mounted || croppedDoc == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not detect the document automatically. Please retake with the full card visible and closer to the camera.',
            ),
          ),
        );
        return;
      }

      _resetScanResults();

      await _processSelfieWithDocument(
        combinedPath: combinedPath,
        croppedDocPath: croppedDoc.path,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _processingMessage = '';
        _recognizedText = 'Error: $e';
      });
    }
  }

  Future<void> _processSelfieWithDocument({
    required String combinedPath,
    required String croppedDocPath,
  }) async {
    final selfiePreview = await autoCropSelfieFacePreview(combinedPath);

    setState(() {
      _isProcessing = true;
      _processingMessage = 'Running OCR and face match…';
      _imageFile = XFile(croppedDocPath);
      _selfieWithDocFile = XFile(combinedPath);
      _selfieFile = selfiePreview != null ? XFile(selfiePreview.path) : null;
    });

    try {
      final results = await Future.wait<Object?>([
        _textRecognizer.processImage(InputImage.fromFilePath(croppedDocPath)),
        _faceMatchService.compareSelfieWithDocument(
          combinedSelfieWithDocPath: combinedPath,
          croppedDocumentPath: croppedDocPath,
        ),
      ]);

      if (!mounted) return;

      final recognizedText = results[0] as RecognizedText;
      final faceResult = results[1] as FaceMatchResult;

      setState(() {
        _recognizedText = recognizedText.text;
        _isProcessing = false;
        _processingMessage = '';
      });
      _applyFaceMatchResult(faceResult);
      _runTemplatePipeline(recognizedText.text);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _processingMessage = '';
        _recognizedText = 'Error: $e';
      });
    }
  }

  Future<void> _reprocessCurrentScan() async {
    final idPath = _imageFile?.path;
    final selfiePath = _selfieFile?.path;
    if (idPath == null || selfiePath == null) return;

    if (_flowMode == ScanFlowMode.awsRekognition) {
      await _processCapturedImagesWithAws(
        idPath: idPath,
        selfiePath: selfiePath,
      );
      return;
    }

    await _processCapturedImages(idPath: idPath, selfiePath: selfiePath);
  }

  Future<void> _changeDocument() async {
    if (_isProcessing) return;

    if (_flowMode == ScanFlowMode.selfieWithDocument) {
      final combined = _selfieWithDocFile?.path;
      if (combined == null) {
        await _scanSelfieWithDocument();
        return;
      }
      final croppedDoc = await DocumentAutoCrop.cropFromPhoto(
        imagePath: combined,
        textRecognizer: _textRecognizer,
      );
      if (!mounted || croppedDoc == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not detect the document automatically. Please retake the photo.',
            ),
          ),
        );
        return;
      }
      await _processSelfieWithDocument(
        combinedPath: combined,
        croppedDocPath: croppedDoc.path,
      );
      return;
    }

    final rawPath = await _captureDocumentPhoto();
    if (!mounted || rawPath == null) return;

    final croppedFile = await _cropDocumentPhoto(rawPath);
    if (!mounted || croppedFile == null) return;

    final selfiePath = _selfieFile?.path;
    if (selfiePath != null) {
      setState(() => _imageFile = XFile(croppedFile.path));
      await _reprocessCurrentScan();
    } else {
      setState(() => _imageFile = XFile(croppedFile.path));
    }
  }

  Future<void> _changeSelfie() async {
    if (_isProcessing) return;

    if (_flowMode == ScanFlowMode.selfieWithDocument) {
      await _scanSelfieWithDocument();
      return;
    }

    final idPath = _imageFile?.path;
    if (idPath == null) {
      await _scanDocument();
      return;
    }

    final selfiePath = await _captureSelfiePhoto();
    if (!mounted || selfiePath == null) return;

    if (_flowMode == ScanFlowMode.awsRekognition) {
      await _processCapturedImagesWithAws(
        idPath: idPath,
        selfiePath: selfiePath,
      );
      return;
    }

    await _processCapturedImages(idPath: idPath, selfiePath: selfiePath);
  }

  void _runTemplatePipeline(String ocrText) {
    final engine = _jsonTemplates;
    if (engine == null) {
      _pendingOcrForJson = ocrText;
      if (_detectedTemplateText != 'Loading…') {
        setState(() => _detectedTemplateText = 'Loading…');
      }
      _loadJsonTemplates();
      return;
    }

    final result = engine.detect(ocrText);
    setState(() {
      _detectedTemplateText = result.displayName;
      _extractedFields = result.fields;
      _detectedDocumentNumber = _pickDocumentNumberFromFields(result.fields);
    });
    _updateDocumentNumberMatch();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OCR Document Scanner')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.document_scanner),
                      label: const Text('Scan ID'),
                      onPressed: _isProcessing ? null : _scanDocument,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.face),
                      label: const Text('Selfie + ID'),
                      onPressed:
                          _isProcessing ? null : _scanSelfieWithDocument,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.cloud_outlined),
                label: const Text('Scan ID (AWS Rekognition)'),
                onPressed: _isProcessing ? null : _scanDocumentWithAws,
              ),
              const SizedBox(height: 16),
              if (_isProcessing) ...[
                const CircularProgressIndicator(),
                if (_processingMessage.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_processingMessage),
                ],
              ],
              if ((_imageFile != null || _selfieFile != null) &&
                  !_isProcessing) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (_imageFile != null)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _changeDocument,
                          icon: const Icon(Icons.badge_outlined),
                          label: const Text('Change document'),
                        ),
                      ),
                    if (_imageFile != null && _selfieFile != null)
                      const SizedBox(width: 8),
                    if (_selfieFile != null)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _changeSelfie,
                          icon: const Icon(Icons.face_retouching_natural),
                          label: const Text('Change selfie'),
                        ),
                      ),
                  ],
                ),
              ],
              if (_imageFile != null && !_isProcessing) ...[
                const SizedBox(height: 12),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Document',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 160,
                  child: Image.file(File(_imageFile!.path)),
                ),
              ],
              if (_selfieFile != null && !_isProcessing) ...[
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Selfie',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 120,
                  child: Image.file(File(_selfieFile!.path)),
                ),
              ],
              const SizedBox(height: 16),
              if (_recognizedText.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Detected: $_detectedTemplateText',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              if (_extractedFields.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _extractedFields.entries.map((e) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: Text('${e.key}: ${e.value}')),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _documentNumberController,
                decoration: const InputDecoration(
                  labelText: 'Enter document number',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _updateDocumentNumberMatch(),
              ),
              const SizedBox(height: 12),
              if (_detectedDocumentNumber != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Detected document number: $_detectedDocumentNumber',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                )
              else if (_recognizedText.isNotEmpty)
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('No document number found in extracted fields.'),
                ),
              const SizedBox(height: 8),
              if (_matchPercent != null && _isDocumentNumberMatch != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Document number match: ${_isDocumentNumberMatch! ? 'True' : 'False'} '
                    '(${_matchPercent!.toStringAsFixed(1)}%)',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color:
                          _isDocumentNumberMatch! ? Colors.green : Colors.red,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              if (_faceMatchError != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _faceMatchError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                )
              else if (_faceMatchPercent != null && _isFaceMatchPass != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Face match: ${_faceMatchPercent!.toStringAsFixed(1)}% '
                        '(${_isFaceMatchPass! ? 'Match' : 'No match'})',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _isFaceMatchPass! ? Colors.green : Colors.red,
                        ),
                      ),
                      // Hidden from end users — keep for debugging if needed later:
                      // Text(
                      //   'Model: ${_faceMatchProvider ?? (_faceUsedEmbeddingModel ? 'MobileFaceNet' : 'Not loaded')}',
                      //   style: Theme.of(context).textTheme.bodySmall,
                      // ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              const Text(
                'Extracted text from document',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              SelectableText(
                _recognizedText.isEmpty
                    ? 'Captured text will appear here.'
                    : _recognizedText,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
