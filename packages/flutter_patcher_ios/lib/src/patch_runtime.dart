import 'dart:async';
import 'dart:typed_data';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/dart_eval_security.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'models.dart';
import 'patch_store.dart';
import 'runtime_contract.dart';

/// Executes only the authenticated, startup-selected local bytecode program.
/// No global overrides, URL loaders, or blanket runtime permissions are used.
class PatchRuntime implements PatchExecution {
  @override
  final PatchStore store;
  final Runtime? _runtime;
  final _errors = StreamController<Object>.broadcast();
  bool _failed = false, _disposed = false;
  PatchRuntime._(this.store, this._runtime);
  @override
  bool get hasPatch => store.active != null;
  @override
  bool get failed => _failed;
  @override
  Stream<Object> get errors => _errors.stream;
  static Future<PatchRuntime> load(PatchStore store) async {
    final package = store.active;
    if (package == null) return PatchRuntime._(store, null);
    if (package.programFormat != PatchProgramFormat.evc) {
      throw const PatchException(
        'INCOMPATIBLE',
        'EVC runtime cannot load a Dart module',
      );
    }
    try {
      final runtime = Runtime(ByteData.sublistView(package.program))
        ..addPlugin(flutterEvalPlugin);
      runtime.grant(_PatchAssetPermission(package.assetPaths.keys.toSet()));
      final identity = runtime.executeLib(
        'package:flutter_patcher_bootstrap/main.dart',
        'runtimeId',
      );
      if ((identity is $Value ? identity.$value : identity) !=
          iosPatchRuntimeId) {
        throw const PatchException(
          'INCOMPATIBLE',
          'Program bootstrap identity mismatch',
        );
      }
      return PatchRuntime._(store, runtime);
    } catch (e) {
      await store.reportFailure('runtime_setup: $e');
      throw PatchException('RUNTIME', 'Cannot load bytecode: $e');
    }
  }

  Future<T> invoke<T>(String id, {List<Object?> arguments = const []}) async {
    if (_disposed || _failed || _runtime == null) {
      throw const PatchException('RUNTIME', 'No usable patched runtime');
    }
    final entry = store.active!.entrypoints[id];
    if (entry == null) {
      throw PatchException('ENTRYPOINT', 'Entrypoint is not installed: $id');
    }
    if (arguments.length != entry.argumentModes.length) {
      throw PatchException(
        'ARGUMENTS',
        'Entrypoint $id requires ${entry.argumentModes.length} arguments',
      );
    }
    for (var i = 0; i < arguments.length; i++) {
      if (entry.argumentModes[i] == 'list' && arguments[i] is! List) {
        throw const PatchException('ARGUMENTS', 'List argument required');
      }
      if (entry.argumentModes[i] == 'raw' &&
          arguments[i] is! num &&
          arguments[i] is! bool) {
        throw const PatchException(
          'ARGUMENTS',
          'Raw mode accepts nonnullable numeric/bool arguments only',
        );
      }
    }
    try {
      // The compiler's declared parameter type, not the value's runtime type,
      // determines boxing. The signed entrypoint contract supplies that ABI.
      final args = [
        for (var i = 0; i < arguments.length; i++)
          switch (entry.argumentModes[i]) {
            'boxed' => _runtime.wrap(arguments[i], recursive: true),
            'list' =>
              (arguments[i] as List)
                  .map((v) => _runtime.wrap(v, recursive: true))
                  .toList(),
            _ => arguments[i],
          },
      ];
      var value = _runtime.executeLib(entry.library, entry.function, args);
      value = value is $Value ? value.$value : value;
      if (value is Future) value = await value;
      value = _unbox(value);
      if (value is! T) {
        throw PatchException('RETURN_TYPE', 'Entrypoint $id did not return $T');
      }
      return value;
    } catch (e) {
      await reportFailure(e);
      throw PatchException('RUNTIME', 'Entrypoint $id failed: $e');
    }
  }

  @override
  Future<void> reportFailure(Object error) async {
    if (_failed || _disposed) return;
    _failed = true;
    try {
      await store.reportFailure(error.toString());
    } finally {
      if (!_errors.isClosed) _errors.add(error);
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _errors.close();
  }

  Object? _unbox(Object? value, [int depth = 0]) {
    if (depth > 64) {
      throw const PatchException(
        'RETURN_TYPE',
        'Returned collection is too deeply nested or cyclic',
      );
    }
    if (value is $Value) {
      final inner = value.$value;
      return identical(inner, value) ? value : _unbox(inner, depth + 1);
    }
    if (value is List) {
      return <dynamic>[for (final v in value) _unbox(v, depth + 1)];
    }
    if (value is Map) {
      final decoded = <Object?, Object?>{
        for (final e in value.entries)
          _unbox(e.key, depth + 1): _unbox(e.value, depth + 1),
      };
      if (decoded.keys.every((k) => k is String)) {
        return <String, dynamic>{
          for (final e in decoded.entries) e.key as String: e.value,
        };
      }
      return decoded;
    }
    return value;
  }
}

class _PatchAssetPermission implements Permission {
  final Set<String> _keys;
  _PatchAssetPermission(Set<String> keys) : _keys = Set.unmodifiable(keys);
  @override
  List<String> get domains => const ['asset'];
  @override
  bool match([Object? data]) => data is String && _keys.contains(data);
}
