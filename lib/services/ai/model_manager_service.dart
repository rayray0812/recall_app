import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
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
/// Subdirectory (under app-support) where downloaded models live.
const _modelsSubdir = 'ai_models';

class ModelManagerService {
  ModelManagerService() {
    // Show a progress notification so the user can leave the screen / lock the
    // phone during a multi-hundred-MB download (the native background task
    // keeps running). Configuring twice is harmless.
    FileDownloader().configureNotification(
      running: const TaskNotification('下載 AI 模型', '{filename}  {progress}'),
      complete: const TaskNotification('AI 模型已下載', '{filename}'),
      error: const TaskNotification('模型下載失敗', '{filename}'),
      progressBar: true,
    );
  }

  /// Directory where downloaded models live.
  @visibleForTesting
  Future<Directory> modelsDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_modelsSubdir');
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

  /// Download a model using the native background downloader, reporting
  /// progress. Runs as an OS background task so it survives the screen locking
  /// or the app being backgrounded, shows a progress notification, and resumes
  /// / retries natively. Returns the final installed path on success.
  Future<String> download(
    AiModelSpec spec, {
    void Function(ModelDownloadProgress)? onProgress,
  }) async {
    final total = spec.sizeMb * 1024 * 1024;
    final task = DownloadTask(
      url: spec.url,
      filename: spec.fileName,
      directory: _modelsSubdir,
      baseDirectory: BaseDirectory.applicationSupport,
      updates: Updates.statusAndProgress,
      retries: 5,
      allowPause: true,
    );

    final result = await FileDownloader().download(
      task,
      onProgress: (progress) {
        // progress is 0.0–1.0, or negative when indeterminate/finished.
        if (progress >= 0) {
          onProgress?.call(
            ModelDownloadProgress(
              receivedBytes: (progress * total).round(),
              totalBytes: total,
            ),
          );
        }
      },
    );

    if (result.status != TaskStatus.complete) {
      final ex = result.exception;
      throw Exception(
        'Model download ${result.status.name}'
        '${ex != null ? ': ${ex.description}' : ''}',
      );
    }
    return task.filePath();
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
