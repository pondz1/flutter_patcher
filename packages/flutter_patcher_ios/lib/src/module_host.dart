import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'asset_bundle.dart';
import 'models.dart';
import 'module_runtime.dart';
import 'patch_client.dart';
import 'patch_store.dart';

/// AOT-owned transport and immutable application/asset selection for one process.
/// The application module reads [current] rather than opening a second store.
class ModulePatchHost {
  static ModulePatchHost? _current;
  static ModulePatchHost? get current => _current;

  final PatchStore store;
  final ModulePatchRuntime runtime;
  final AssetBundle bundledAssets;
  final PatchAssetBundle assets;
  final Uri checkUrl;
  final PatchClient _client;
  bool _bootConfirmed;
  bool _rollbackRequested = false;
  Future<bool>? _checking;
  Future<void>? _rollingBack, _closing, _running;

  ModulePatchHost._(
    this.store,
    this.runtime,
    this.bundledAssets,
    this.checkUrl,
    this._client,
  ) : assets = PatchAssetBundle(package: store.active, fallback: bundledAssets),
      _bootConfirmed = !runtime.hasPatch;

  static Future<ModulePatchHost> open({
    required PatchHost host,
    required Map<String, List<int>> trustedKeys,
    required Uri apiBase,
    required AssetBundle bundledAssets,
    Directory? directory,
    bool allowLocalHttp = false,
    ModuleProgramLoader? loader,
  }) async {
    if (host.programFormat != PatchProgramFormat.dartBytecodeV3 ||
        host.entrypoints.length != 1 ||
        !host.entrypoints.contains('app.main') ||
        trustedKeys.isEmpty) {
      throw const PatchException(
        'INVALID_HOST',
        'Explicit module trust and identity required',
      );
    }
    final location =
        directory ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}/flutter_patcher_ios_modules',
        );
    final store = await PatchStore.open(
      directory: location,
      host: host,
      trustedKeys: trustedKeys,
    );
    try {
      final runtime = ModulePatchRuntime(store, loader: loader);
      final url = apiBase.replace(
        path:
            '${apiBase.path.replaceFirst(RegExp(r'/+$'), '')}/app-release/patches/check/',
        queryParameters: {
          'platform': 'ios',
          'app_id': host.appId,
          'version': host.version,
          'build_number': host.buildNumber,
          'runtime_id': host.runtimeId,
          'api_id': host.apiId,
        },
        fragment: '',
      );
      return ModulePatchHost._(
        store,
        runtime,
        bundledAssets,
        url,
        PatchClient(store, allowLocalHttp: allowLocalHttp),
      );
    } catch (_) {
      await store.close();
      rethrow;
    }
  }

  /// Called after the bootstrap installed [assets] as its process root bundle.
  Future<void> runApplication(String bundledProgramAsset) {
    if (_running != null || _closing != null || _current != null) {
      return Future.error(
        StateError('Application generation already selected'),
      );
    }
    _current = this;
    return _running = (() async {
      try {
        var fallback = Uint8List(0);
        if (store.active == null) {
          final data = await bundledAssets.load(bundledProgramAsset);
          fallback = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        }
        await runtime.run(fallback);
      } catch (error) {
        await runtime.reportFailure(error);
        rethrow;
      }
    })();
  }

  void markBootConfirmed() => _bootConfirmed = true;

  Future<bool> checkAndInstall() {
    if (!_bootConfirmed ||
        runtime.failed ||
        _closing != null ||
        _rollbackRequested) {
      return Future.value(false);
    }
    return _checking ??= (() async {
      try {
        return await _client.checkAndInstall(checkUrl);
      } finally {
        _checking = null;
      }
    })();
  }

  Future<void> rollback() {
    _rollbackRequested = true;
    return _rollingBack ??= (() async {
      try {
        try {
          await _checking;
        } catch (_) {
          // A failed download must not prevent rollback.
        }
        await store.rollback();
      } finally {
        _rollingBack = null;
      }
    })();
  }

  Future<void> close() => _closing ??= (() async {
    try {
      for (final operation in [_checking, _rollingBack, _running]) {
        try {
          await operation;
        } catch (_) {
          // Each operation reports its own error. Cleanup must await all owners.
        }
      }
    } finally {
      await runtime.dispose();
      await store.close();
    }
  })();
}
