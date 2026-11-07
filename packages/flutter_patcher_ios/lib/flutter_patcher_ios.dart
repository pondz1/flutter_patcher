/// Authenticated, self-hosted code and asset patches for prepared entrypoints.
/// Requires shipping this runtime in the base app. Does not replace AOT code.
library;

export 'core.dart';
export 'src/patch_runtime.dart';
export 'src/boot_guard.dart';
