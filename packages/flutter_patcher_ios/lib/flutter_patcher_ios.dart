/// Authenticated, self-hosted code and asset patches for prepared entrypoints.
/// Requires shipping this runtime in the base app. Does not replace AOT code.
library;

export 'src/models.dart'
    show
        PatchHost,
        PatchEnvelope,
        PatchException,
        PatchLimits,
        PatchPackage,
        PatchEntrypoint,
        iosPatchRuntimeId;
export 'src/patch_store.dart';
export 'src/patch_runtime.dart';
export 'src/asset_bundle.dart';
export 'src/boot_guard.dart';
export 'src/patch_client.dart';
