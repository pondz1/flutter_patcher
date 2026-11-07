import 'dart:typed_data';

/// Compiler and runtime must use exactly this bridge/bytecode combination.
const iosPatchRuntimeId = 'dart_eval-0.8.5/flutter_eval-0.8.2-fp.1';
const iosDartModuleRuntimeId =
    'dart-ddm-v3/3f287915e06d8f802799c02c333da32e2b7d8dac';

enum PatchProgramFormat {
  evc,
  dartBytecodeV3;

  bool acceptsHeader(Uint8List program) {
    if (program.length < 8) return false;
    final header = ByteData.sublistView(program);
    return switch (this) {
      evc => header.getUint32(0) == 0x45564300 && header.getInt32(4) == 81,
      dartBytecodeV3 =>
        header.getUint32(0) == 0x33434244 &&
            header.getUint32(4, Endian.little) == 3,
    };
  }
}

class PatchException implements Exception {
  final String code;
  final String message;
  const PatchException(this.code, this.message);
  @override
  String toString() => 'PatchException($code): $message';
}

class PatchLimits {
  final int maxZipBytes, maxExpandedBytes, maxFileBytes, maxEntries;
  const PatchLimits({
    this.maxZipBytes = 25 * 1024 * 1024,
    this.maxExpandedBytes = 100 * 1024 * 1024,
    this.maxFileBytes = 20 * 1024 * 1024,
    this.maxEntries = 10000,
  });
}

class PatchHost {
  final String appId, version, buildNumber, apiId;
  final Set<String> entrypoints;
  final PatchProgramFormat programFormat;
  const PatchHost({
    required this.appId,
    required this.version,
    required this.buildNumber,
    required this.apiId,
    required this.entrypoints,
    this.programFormat = PatchProgramFormat.evc,
  });
  String get runtimeId => switch (programFormat) {
    PatchProgramFormat.evc => iosPatchRuntimeId,
    PatchProgramFormat.dartBytecodeV3 => iosDartModuleRuntimeId,
  };
  Map<String, dynamic> toJson() => {
    'appId': appId,
    'version': version,
    'buildNumber': buildNumber,
    'apiId': apiId,
  };
}

class PatchEnvelope {
  final String version, sha256, keyId, signature;
  final int size;
  final Uri downloadUrl;
  const PatchEnvelope({
    required this.version,
    required this.sha256,
    required this.size,
    required this.keyId,
    required this.signature,
    required this.downloadUrl,
  });
  factory PatchEnvelope.fromJson(Map<String, dynamic> json) => PatchEnvelope(
    version: requiredString(json, 'version'),
    sha256: requiredString(json, 'sha256'),
    size: requiredInt(json, 'size'),
    keyId: requiredString(json, 'keyId'),
    signature: requiredString(json, 'signature'),
    downloadUrl: Uri.parse(requiredString(json, 'downloadUrl')),
  );
  Map<String, dynamic> toJson() => {
    'version': version,
    'sha256': sha256,
    'size': size,
    'keyId': keyId,
    'signature': signature,
    'downloadUrl': downloadUrl.toString(),
  };
}

class PatchEntrypoint {
  final String library, function;
  final List<String> argumentModes;
  PatchEntrypoint(
    this.library,
    this.function, {
    List<String> argumentModes = const [],
  }) : argumentModes = List.unmodifiable(argumentModes);
}

/// In-memory immutable contents of one authenticated package.
class PatchPackage {
  final String version, digest;
  final Map<String, PatchEntrypoint> entrypoints;
  final Map<String, String> assetPaths;
  final Map<String, Uint8List> _files;
  final String programPath;
  final PatchProgramFormat programFormat;
  PatchPackage({
    required this.version,
    required this.digest,
    required Map<String, PatchEntrypoint> entrypoints,
    required Map<String, String> assetPaths,
    required Map<String, Uint8List> files,
    required this.programPath,
    this.programFormat = PatchProgramFormat.evc,
  }) : entrypoints = Map.unmodifiable(entrypoints),
       assetPaths = Map.unmodifiable(assetPaths),
       _files = Map.unmodifiable(
         files.map((k, v) => MapEntry(k, v.asUnmodifiableView())),
       );
  Uint8List get program => _files[programPath]!;
  Uint8List? asset(String key) => _files[assetPaths[key]];
}

String requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw PatchException('INVALID_PACKAGE', 'Expected nonempty string: $key');
  }
  return value;
}

int requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) {
    throw PatchException(
      'INVALID_PACKAGE',
      'Expected nonnegative integer: $key',
    );
  }
  return value;
}

Map<String, dynamic> objectMap(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const PatchException('INVALID_PACKAGE', 'Expected JSON object');
  }
  return value;
}

void validatePatchPath(String path) {
  if (path.isEmpty ||
      path.contains('\\') ||
      path.contains(':') ||
      path.contains('\u0000') ||
      path.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
    throw PatchException('UNSAFE_PATH', 'Invalid package path: $path');
  }
}
