import 'dart:async';
import 'dart:typed_data';

import 'package:dynamic_modules/dynamic_modules.dart' as modules;

import 'models.dart';
import 'patch_store.dart';
import 'runtime_contract.dart';

typedef ModuleProgramLoader = Future<Object?> Function(Uint8List program);

/// Loads one entire application, never a replacement in an already used isolate.
class ModulePatchRuntime implements PatchExecution {
  @override
  final PatchStore store;
  final ModuleProgramLoader _loader;
  final _errors = StreamController<Object>.broadcast();
  bool _started = false, _failed = false, _disposed = false;

  ModulePatchRuntime(this.store, {ModuleProgramLoader? loader})
    : _loader = loader ?? modules.loadModuleFromBytes {
    if (store.codec.host.programFormat != PatchProgramFormat.dartBytecodeV3) {
      throw const PatchException('INCOMPATIBLE', 'A module host is required');
    }
  }

  @override
  bool get hasPatch => store.active != null;
  @override
  bool get failed => _failed;
  @override
  Stream<Object> get errors => _errors.stream;

  Future<void> run(Uint8List bundledProgram) async {
    if (_started || _disposed) {
      throw StateError('A module can only be loaded once per process');
    }
    // A failed load can have registered declarations or started asynchronous
    // work. Even a failure must not make another load possible in this isolate.
    _started = true;
    try {
      final selected = store.active;
      if (selected != null &&
          selected.programFormat != PatchProgramFormat.dartBytecodeV3) {
        throw const PatchException(
          'INCOMPATIBLE',
          'Selected code is not a module',
        );
      }
      final program = Uint8List.fromList(selected?.program ?? bundledProgram);
      if (!PatchProgramFormat.dartBytecodeV3.acceptsHeader(program)) {
        throw const PatchException('INCOMPATIBLE', 'Invalid module header');
      }
      final result = await _loader(program.asUnmodifiableView());
      if (result != null) {
        throw const PatchException(
          'ENTRYPOINT',
          'Application main must return void',
        );
      }
    } catch (error) {
      await reportFailure(error);
      throw PatchException('RUNTIME', 'Application module failed: $error');
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
    if (_disposed) return;
    _disposed = true;
    await _errors.close();
  }
}
