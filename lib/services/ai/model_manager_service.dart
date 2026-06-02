import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:recall_app/services/ai/ai_model_catalog.dart';

/// Install state of an on-device model.
enum ModelInstallState { notInstalled, downloading, ready, error }

/// Progress for an in-flight download.
@immutable
class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;
  final int totalBytes;

  /// 0.0–1.0, or null when the total size is unknown.
  double? get fraction =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
}

/// Downloads, stores, and removes on-device model files.
///
/// Replaces the old "manually import a .litertlm file" flow: the app now
/// downloads the right model for the device on first use (WiFi recommended)
/// and tracks it on disk. Models are NOT bundled in the app binary, keeping
/// the install size small (see audit #12 in prelaunch-audit).
class ModelManagerService {
  ModelManagerService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// Directory where downloaded models live.
  @visibleForTesting
  Future<Directory> modelsDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/ai_models');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _fileFor(AiModelSpec spec) async {
    final dir = await modelsDir();
    return File('${dir.path}/${spec.fileName}');
  }

  /// Absolute path to the installed model file, or null if not installed.
  Future<String?> installedPath(AiModelSpec spec) async {
    final file = await _fileFor(spec);
    return await file.exists() ? file.path : null;
  }

  Future<bool> isInstalled(AiModelSpec spec) async =>
      (await _fileFor(spec)).exists();

  Future<ModelInstallState> stateOf(AiModelSpec spec) async {
    final file = await _fileFor(spec);
    if (await file.exists()) return ModelInstallState.ready;
    final partial = File('${file.path}.part');
    if (await partial.exists()) return ModelInstallState.downloading;
    return ModelInstallState.notInstalled;
  }

  /// Stream a model to disk, reporting progress. Writes to a `.part` file and
  /// atomically renames on success so a half-finished download is never seen
  /// as ready. Returns the final installed path.
  Future<String> download(
    AiModelSpec spec, {
    void Function(ModelDownloadProgress)? onProgress,
  }) async {
    final file = await _fileFor(spec);
    final tmp = File('${file.path}.part');

    final request = http.Request('GET', Uri.parse(spec.url));
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw HttpException(
        'Model download failed (HTTP ${response.statusCode})',
        uri: Uri.parse(spec.url),
      );
    }

    final total = response.contentLength ?? (spec.sizeMb * 1024 * 1024);
    var received = 0;
    final sink = tmp.openWrite();
    try {
      await for (final chunk in response.stream) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(
          ModelDownloadProgress(receivedBytes: received, totalBytes: total),
        );
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    await tmp.rename(file.path);
    return file.path;
  }

  /// Remove an installed model (and any partial download) to free space.
  Future<void> delete(AiModelSpec spec) async {
    final file = await _fileFor(spec);
    if (await file.exists()) await file.delete();
    final partial = File('${file.path}.part');
    if (await partial.exists()) await partial.delete();
  }

  /// Total bytes used by all installed models.
  Future<int> totalInstalledBytes() async {
    final dir = await modelsDir();
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is File && !entity.path.endsWith('.part')) {
        total += await entity.length();
      }
    }
    return total;
  }
}
