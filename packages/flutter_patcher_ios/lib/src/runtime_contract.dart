import 'patch_store.dart';

/// One startup-selected execution generation observed by the boot guard.
abstract interface class PatchExecution {
  PatchStore get store;
  bool get hasPatch;
  bool get failed;
  Stream<Object> get errors;
  Future<void> reportFailure(Object error);
  Future<void> dispose();
}
