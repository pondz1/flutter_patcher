import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'models.dart';
import 'package_codec.dart';

/// Owns one storage directory. Close before opening it in another process/test.
/// The active in-memory package never changes for the lifetime of this object.
class PatchStore {
  static final _owners = <String>{};
  final Directory directory;
  final PatchPackageCodec codec;
  final RandomAccessFile _lock;
  Map<String, dynamic> _state = {};
  PatchPackage? _active;
  String? _pendingVersion;
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  bool _closed = false;
  PatchStore._(this.directory, this.codec, this._lock);

  PatchPackage? get active => _active;
  String? get pendingVersion => _pendingVersion;
  String get diagnostic => _state['diagnostic'] as String? ?? 'no_patch';
  Map<String, String> get blacklist =>
      Map.unmodifiable(Map<String, String>.from(_state['blacklist'] as Map));

  static Future<PatchStore> open({
    Directory? directory,
    required PatchHost host,
    required Map<String, List<int>> trustedKeys,
    PatchLimits limits = const PatchLimits(),
  }) async {
    if ([
      host.appId,
      host.version,
      host.buildNumber,
      host.apiId,
    ].any((s) => s.isEmpty)) {
      throw const PatchException(
        'INVALID_HOST',
        'Host identity must be explicit',
      );
    }
    final root =
        directory ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}/flutter_patcher_ios',
        );
    await root.create(recursive: true);
    final resolved = await root.resolveSymbolicLinks();
    if (!_owners.add(resolved)) {
      throw const PatchException('IN_USE', 'Patch storage already open');
    }
    RandomAccessFile? lock;
    try {
      lock = await File('$resolved/store.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final store = PatchStore._(
        Directory(resolved),
        PatchPackageCodec(host: host, trustedKeys: trustedKeys, limits: limits),
        lock,
      );
      await store._boot();
      return store;
    } catch (_) {
      await lock?.close();
      _owners.remove(resolved);
      rethrow;
    }
  }

  Map<String, dynamic> _empty() => {
    'schemaVersion': 1,
    'selected': null,
    'healthy': null,
    'previous': null,
    'attempt': null,
    'attempts': 0,
    'blacklist': <String, String>{},
    'disabled': <String>[],
    'diagnostic': 'no_patch',
  };
  Map<String, dynamic> _copy() => objectMap(jsonDecode(jsonEncode(_state)));
  static bool _digest(Object? value) =>
      value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
  void _validateState(Map<String, dynamic> state) {
    if (state['schemaVersion'] != 1 ||
        state['attempts'] is! int ||
        (state['attempts'] as int) < 0 ||
        state['blacklist'] is! Map ||
        state['disabled'] is! List ||
        state['diagnostic'] is! String ||
        (state['blacklist'] as Map).entries.any(
          (e) => !_digest(e.key) || e.value is! String,
        ) ||
        (state['disabled'] as List).any((e) => !_digest(e))) {
      throw const PatchException('STATE', 'Invalid patch state');
    }
    for (final key in ['selected', 'healthy', 'previous', 'attempt']) {
      if (state[key] != null && !_digest(state[key])) {
        throw const PatchException('STATE', 'Invalid generation pointer');
      }
    }
  }

  Future<Uint8List> _read(File file, int limit) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > limit) {
      throw const PatchException(
        'STATE',
        'Missing, linked, or oversized patch file',
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > limit) {
      throw const PatchException('LIMIT', 'File exceeds size limit');
    }
    return bytes;
  }

  Future<PatchPackage> _load(String digest) async {
    if (!_digest(digest)) {
      throw const PatchException('STATE', 'Invalid generation digest');
    }
    final path = '${directory.path}/generations/$digest';
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const PatchException('STATE', 'Missing generation directory');
    }
    final env = PatchEnvelope.fromJson(
      objectMap(
        jsonDecode(
          utf8.decode(await _read(File('$path/envelope.json'), 64 * 1024)),
        ),
      ),
    );
    if (env.sha256 != digest) {
      throw const PatchException('STATE', 'Generation digest mismatch');
    }
    return codec.verify(
      await _read(File('$path/payload.zip'), codec.limits.maxZipBytes),
      env,
    );
  }

  String? _fallback(Map<String, dynamic> state, String rejected) {
    for (final key in ['healthy', 'previous']) {
      final value = state[key];
      if (value is String &&
          value != rejected &&
          !(state['blacklist'] as Map).containsKey(value) &&
          !(state['disabled'] as List).contains(value)) {
        return value;
      }
    }
    return null;
  }

  Future<void> _boot() async {
    var state = _empty();
    final file = File('${directory.path}/state.json');
    if (await file.exists()) {
      try {
        state = objectMap(
          jsonDecode(utf8.decode(await _read(file, 1024 * 1024))),
        );
        _validateState(state);
      } on PatchException {
        state = _empty()..['diagnostic'] = 'corrupt_state';
      } on FormatException {
        state = _empty()..['diagnostic'] = 'corrupt_state';
      }
    }
    var selected = state['selected'] as String?;
    while (selected != null) {
      String? reason;
      if ((state['blacklist'] as Map).containsKey(selected) ||
          (state['disabled'] as List).contains(selected)) {
        reason = 'disabled_generation';
      } else if (state['attempt'] == selected &&
          (state['attempts'] as int) >= 2) {
        reason = 'interrupted_launch_threshold';
      } else {
        try {
          _active = await _load(selected);
        } catch (e) {
          reason = 'startup_validation: $e';
        }
      }
      if (reason == null) break;
      (state['blacklist'] as Map)[selected] = reason;
      state['diagnostic'] = reason;
      selected = _fallback(state, selected);
      state['selected'] = selected;
      state['attempt'] = null;
      state['attempts'] = 0;
    }
    if (_active != null) {
      final digest = _active!.digest;
      state['attempts'] = state['attempt'] == digest
          ? (state['attempts'] as int) + 1
          : 1;
      state['attempt'] = digest;
      state['diagnostic'] = 'patched';
    }
    await _commit(state);
  }

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (_closed) {
          throw const PatchException('CLOSED', 'Patch store is closed');
        }
        result.complete(await work());
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  Future<void> _commit(Map<String, dynamic> next) async {
    _validateState(next);
    final temp = File('${directory.path}/state.next');
    // A previous interrupted write is never considered committed state.
    if (await FileSystemEntity.type(temp.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await temp.delete();
    }
    await temp.writeAsString(jsonEncode(next), flush: true);
    await temp.rename('${directory.path}/state.json');
    _state = next;
  }

  Future<void> install(Uint8List bytes, PatchEnvelope envelope) =>
      _serial(() async {
        if (bytes.isEmpty || bytes.length > codec.limits.maxZipBytes) {
          throw const PatchException('LIMIT', 'Payload exceeds ZIP limit');
        }
        final snapshot = Uint8List.fromList(bytes);
        final package = await codec.verify(snapshot, envelope);
        final digest = package.digest;
        if ((_state['blacklist'] as Map).containsKey(digest) ||
            (_state['disabled'] as List).contains(digest)) {
          throw const PatchException(
            'BLACKLISTED',
            'Generation rejected or rolled back',
          );
        }
        if (_state['selected'] == digest) {
          _pendingVersion = package.version;
          return;
        }
        if (_active != null && _state['attempt'] == _active!.digest) {
          throw const PatchException(
            'BOOT_PENDING',
            'Confirm current boot before installing another patch',
          );
        }
        final generations = Directory('${directory.path}/generations');
        await generations.create(recursive: true);
        final target = Directory('${generations.path}/$digest');
        if (await target.exists()) {
          await _load(digest);
        } else {
          final staging = await generations.createTemp('.staging-');
          try {
            await File(
              '${staging.path}/payload.zip',
            ).writeAsBytes(snapshot, flush: true);
            await File(
              '${staging.path}/envelope.json',
            ).writeAsString(jsonEncode(envelope.toJson()), flush: true);
            await staging.rename(target.path);
          } finally {
            if (await staging.exists()) await staging.delete(recursive: true);
          }
        }
        final next = _copy()..['selected'] = digest;
        await _commit(next);
        _pendingVersion = package.version;
      });
  Future<void> confirmBoot() => _serial(() async {
    final digest = _active?.digest;
    if (digest == null || _state['attempt'] != digest) return;
    final next = _copy();
    if (next['healthy'] != digest) {
      next['previous'] = next['healthy'];
      next['healthy'] = digest;
    }
    next['attempt'] = null;
    next['attempts'] = 0;
    next['diagnostic'] = 'healthy';
    await _commit(next);
  });
  Future<void> reportFailure(String reason) => _serial(() async {
    final digest = _active?.digest;
    if (digest == null) return;
    final next = _copy();
    (next['blacklist'] as Map)[digest] = reason;
    if (next['selected'] == digest) next['selected'] = _fallback(next, digest);
    next['attempt'] = null;
    next['attempts'] = 0;
    next['diagnostic'] = 'runtime_failure: $reason';
    await _commit(next);
  });
  Future<void> rollback() => _serial(() async {
    final digest = _state['selected'] as String?;
    if (digest == null) return;
    final next = _copy();
    if (!(next['disabled'] as List).contains(digest)) {
      (next['disabled'] as List).add(digest);
    }
    next['selected'] = _fallback(next, digest);
    next['attempt'] = null;
    next['attempts'] = 0;
    next['diagnostic'] = 'manual_rollback';
    await _commit(next);
    _pendingVersion = null;
  });
  Future<void> close() => _closing ??= _serial(() async {
    _closed = true;
    try {
      await _lock.unlock();
    } finally {
      await _lock.close();
      _owners.remove(directory.path);
    }
  });
}
