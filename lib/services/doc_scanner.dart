import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Pictures from "Take a photo".
class ScanShots {
  const ScanShots(this.paths, {required this.fromScanner});

  final List<String> paths;

  /// true = they came from the document scanner (already found, cropped and straightened, so
  /// "Choose cropping method" is skipped); false = plain camera photos.
  final bool fromScanner;
}

/// "Take a photo": Google's ML Kit document scanner on Android / VisionKit on iOS — live page
/// edge detection, several pages in a row, automatic crop and straightening. When the scanner
/// can't start (no Google Play services, old device…) the plain camera opens instead.
/// Returns null when the person backs out.
/// [preferInAppCamera] skips the document scanner and opens the plain camera. Android uses that
/// because the system scanner's close control was not leaving the screen. On iOS, Scan to PDF and
/// Image to PDF → Take a photo leave this false so Apple's VisionKit document scanner opens.
/// The plain camera is only the fallback when that scanner cannot start. Callers must wait until
/// any sheet has finished closing first.
Future<ScanShots?> takeDocumentPhotos({int maxPages = 50, bool preferInAppCamera = false}) async {
  if (!preferInAppCamera) {
    final first = await _documentScanner(maxPages);
    if (first.opened) return first.shots;
    // The option sheet can still own the screen for one frame. Try Apple's scanner once more
    // before giving up on it.
    if (Platform.isIOS) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final second = await _documentScanner(maxPages);
      if (second.opened) return second.shots;
    }
  }
  return _plainCamera();
}

/// [opened] false means the scanner never appeared, so the plain camera may be tried.
/// [opened] true with null [shots] means the person backed out or denied the camera.
Future<({bool opened, ScanShots? shots})> _documentScanner(int maxPages) async {
  try {
    final pictures = await CunningDocumentScanner.getPictures(
      noOfPages: maxPages,
      scannerSource: ScannerSource.camera,
    );
    if (pictures == null || pictures.isEmpty) return (opened: true, shots: null);
    return (opened: true, shots: ScanShots(await _keep(pictures), fromScanner: true));
  } on CunningDocumentScannerException catch (error) {
    if (error.code == 'permission_denied') return (opened: true, shots: null);
    debugPrint('document scanner unavailable: $error');
    return (opened: false, shots: null);
  } catch (error) {
    debugPrint('document scanner unavailable: $error');
    return (opened: false, shots: null);
  }
}

Future<ScanShots?> _plainCamera() async {
  try {
    final shot = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 95);
    if (shot == null) return null;
    return ScanShots([shot.path], fromScanner: false);
  } catch (_) {
    return null;
  }
}

/// "Choose from gallery": several pictures; empty when the person backs out.
Future<List<String>> pickGalleryImages() async {
  try {
    final files = await ImagePicker().pickMultiImage(imageQuality: 95);
    return [for (final file in files) file.path];
  } catch (_) {
    return const [];
  }
}

/// The scanner keeps its pictures in its own folder, which it may clean; copy them to ours.
Future<List<String>> _keep(List<String> paths) async {
  final dir = Directory(p.join((await getTemporaryDirectory()).path, 'scan'));
  await dir.create(recursive: true);
  final out = <String>[];
  for (var i = 0; i < paths.length; i++) {
    final source = File(paths[i]);
    if (!await source.exists()) continue;
    final ext = p.extension(paths[i]).isEmpty ? '.jpg' : p.extension(paths[i]);
    final target = p.join(dir.path, 'scan_${DateTime.now().microsecondsSinceEpoch}_$i$ext');
    try {
      await source.copy(target);
      out.add(target);
    } catch (_) {
      out.add(paths[i]);
    }
  }
  return out;
}
