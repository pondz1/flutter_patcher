import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'models.dart';

List<int> patchSigningMessage(String digest) =>
    utf8.encode('flutter_patcher:ios:v1\n$digest');

class PatchPackageCodec {
  final PatchHost host;
  final Map<String, List<int>> trustedKeys;
  final PatchLimits limits;
  PatchPackageCodec({
    required this.host,
    required Map<String, List<int>> trustedKeys,
    this.limits = const PatchLimits(),
  }) : trustedKeys = Map.unmodifiable(
         trustedKeys.map((k, v) => MapEntry(k, List<int>.unmodifiable(v))),
       );

  Future<PatchPackage> verify(Uint8List bytes, PatchEnvelope envelope) async {
    try {
      if (bytes.isEmpty || bytes.length > limits.maxZipBytes) {
        throw const PatchException('LIMIT', 'Payload exceeds ZIP limit');
      }
      return await _verify(Uint8List.fromList(bytes), envelope);
    } on PatchException {
      rethrow;
    } catch (e) {
      throw PatchException('INVALID_PACKAGE', 'Invalid patch: $e');
    }
  }

  Future<PatchPackage> _verify(Uint8List bytes, PatchEnvelope envelope) async {
    if (bytes.isEmpty ||
        bytes.length > limits.maxZipBytes ||
        bytes.length != envelope.size ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(envelope.sha256) ||
        hash.sha256.convert(bytes).toString() != envelope.sha256) {
      throw const PatchException(
        'INTEGRITY',
        'Payload size or SHA-256 mismatch',
      );
    }
    final key = trustedKeys[envelope.keyId];
    if (key == null || key.length != 32) {
      throw const PatchException('SIGNATURE', 'Unknown signing key');
    }
    final signature = base64Decode(envelope.signature);
    if (signature.length != 64 ||
        !await Ed25519().verify(
          patchSigningMessage(envelope.sha256),
          signature: Signature(
            signature,
            publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
          ),
        )) {
      throw const PatchException('SIGNATURE', 'Invalid patch signature');
    }
    // Preflight raw central-directory headers: Archive itself coalesces duplicate
    // paths and may decompress symlink targets before callers see the entries.
    final directory = ZipDirectory()
      ..read(InputMemoryStream(bytes), verify: true);
    if (directory.fileHeaders.isEmpty ||
        directory.fileHeaders.length > limits.maxEntries) {
      throw const PatchException('LIMIT', 'Too many ZIP entries');
    }
    var expanded = 0;
    final paths = <String>{};
    for (final header in directory.fileHeaders) {
      validatePatchPath(header.filename);
      final local = header.file;
      if (local == null ||
          (local.flags & 0x9) != 0 ||
          (local.compressionMethod != CompressionType.none &&
              local.compressionMethod != CompressionType.deflate) ||
          local.uncompressedSize != header.uncompressedSize ||
          local.compressedSize != header.compressedSize) {
        throw const PatchException(
          'UNSUPPORTED_ZIP',
          'Only unencrypted STORED/DEFLATE ZIPs without data descriptors are supported',
        );
      }
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      if (!paths.add(header.filename) ||
          (type != 0 && type != 0x8000) ||
          header.uncompressedSize < 0 ||
          header.uncompressedSize > limits.maxFileBytes) {
        throw const PatchException(
          'INVALID_PACKAGE',
          'Duplicate, nonregular, or oversized ZIP entry',
        );
      }
      expanded += header.uncompressedSize;
      if (expanded > limits.maxExpandedBytes) {
        throw const PatchException('LIMIT', 'Expanded ZIP limit exceeded');
      }
    }
    final zip = ZipDecoder().decodeBytes(
      bytes,
      verify: true,
      throwOnError: true,
    );
    final files = <String, Uint8List>{};
    var actualExpanded = 0;
    for (final entry in zip) {
      if (!entry.isFile || entry.isSymbolicLink) {
        throw const PatchException(
          'INVALID_PACKAGE',
          'Only regular files allowed',
        );
      }
      // archive 4.6.0 bounds decompression to the declared size and checks CRC.
      final content = entry.readBytes();
      if (content == null ||
          content.length != entry.size ||
          content.length > limits.maxFileBytes) {
        throw const PatchException('LIMIT', 'Invalid expanded file size');
      }
      actualExpanded += content.length;
      if (actualExpanded > limits.maxExpandedBytes) {
        throw const PatchException(
          'LIMIT',
          'Actual expanded ZIP limit exceeded',
        );
      }
      files[entry.name] = Uint8List.fromList(content);
    }
    final manifestBytes = files.remove('manifest.json');
    if (manifestBytes == null || manifestBytes.length > 1024 * 1024) {
      throw const PatchException(
        'INVALID_PACKAGE',
        'Missing or oversized manifest',
      );
    }
    final manifest = objectMap(jsonDecode(utf8.decode(manifestBytes)));
    final format = manifest.containsKey('programFormat')
        ? manifest['programFormat']
        : 'evc-v81';
    final expectedFormat = switch (host.programFormat) {
      PatchProgramFormat.evc => 'evc-v81',
      PatchProgramFormat.dartBytecodeV3 => 'dart-bytecode-v3',
    };
    if (manifest['schemaVersion'] != 1 ||
        manifest['platform'] != 'ios' ||
        format != expectedFormat ||
        manifest['runtimeId'] != host.runtimeId ||
        manifest['version'] != envelope.version) {
      throw const PatchException(
        'INCOMPATIBLE',
        'Unsupported schema, platform, runtime, or version',
      );
    }
    final target = objectMap(manifest['host']);
    for (final entry in host.toJson().entries) {
      if (target[entry.key] != entry.value) {
        throw const PatchException(
          'INCOMPATIBLE',
          'Patch targets a different host release/API',
        );
      }
    }
    final metadata = objectMap(manifest['files']);
    if (metadata.length != files.length ||
        !files.keys.every(metadata.containsKey)) {
      throw const PatchException(
        'INVALID_PACKAGE',
        'Manifest must list every file exactly once',
      );
    }
    for (final entry in files.entries) {
      final info = objectMap(metadata[entry.key]);
      if (info['size'] != entry.value.length ||
          info['sha256'] != hash.sha256.convert(entry.value).toString()) {
        throw const PatchException(
          'INTEGRITY',
          'File size or SHA-256 mismatch',
        );
      }
    }
    final program = requiredString(manifest, 'program');
    validatePatchPath(program);
    if (!program.startsWith('code/') ||
        !files.containsKey(program) ||
        files[program]!.isEmpty) {
      throw const PatchException('INVALID_PACKAGE', 'Missing bytecode program');
    }
    final bytecode = files[program]!;
    final header = bytecode.length < 8 ? null : ByteData.sublistView(bytecode);
    final validHeader =
        header != null &&
        switch (host.programFormat) {
          PatchProgramFormat.evc =>
            header.getUint32(0) == 0x45564300 && header.getInt32(4) == 81,
          PatchProgramFormat.dartBytecodeV3 =>
            header.getUint32(0) == 0x33434244 &&
                header.getUint32(4, Endian.little) == 3,
        };
    if (!validHeader) {
      throw const PatchException(
        'INCOMPATIBLE',
        'Invalid program header or bytecode version',
      );
    }
    final declarations = objectMap(manifest['entrypoints']);
    if (host.programFormat == PatchProgramFormat.dartBytecodeV3 &&
        (declarations.length != 1 || !declarations.containsKey('app.main'))) {
      throw const PatchException(
        'INCOMPATIBLE',
        'Module requires only app.main',
      );
    }
    final entrypoints = <String, PatchEntrypoint>{};
    for (final entry in declarations.entries) {
      if (!host.entrypoints.contains(entry.key)) {
        throw PatchException(
          'INCOMPATIBLE',
          'Unknown host entrypoint: ${entry.key}',
        );
      }
      final spec = objectMap(entry.value);
      final modes = host.programFormat == PatchProgramFormat.dartBytecodeV3
          ? (spec.containsKey('argumentModes')
                ? spec['argumentModes']
                : const <String>[])
          : spec['argumentModes'] ?? const <String>[];
      if (modes is! List ||
          modes.length > 64 ||
          modes.any((v) => v != 'raw' && v != 'boxed' && v != 'list')) {
        throw const PatchException(
          'INVALID_PACKAGE',
          'Invalid entrypoint argument modes',
        );
      }
      if (host.programFormat == PatchProgramFormat.dartBytecodeV3 &&
          modes.isNotEmpty) {
        throw const PatchException(
          'INCOMPATIBLE',
          'Module main takes no arguments',
        );
      }
      entrypoints[entry.key] = PatchEntrypoint(
        requiredString(spec, 'library'),
        requiredString(spec, 'function'),
        argumentModes: List<String>.from(modes),
      );
    }
    if (entrypoints.isEmpty) {
      throw const PatchException('INVALID_PACKAGE', 'No code entrypoints');
    }
    final assets = <String, String>{};
    for (final entry in objectMap(manifest['assets']).entries) {
      validatePatchPath(entry.key);
      final path = entry.value;
      if (path is! String) {
        throw const PatchException('INVALID_PACKAGE', 'Invalid asset path');
      }
      validatePatchPath(path);
      if (!path.startsWith('assets/') || !files.containsKey(path)) {
        throw const PatchException('INVALID_PACKAGE', 'Missing overlay asset');
      }
      assets[entry.key] = path;
    }
    if (files.keys.any((p) => p != program && !assets.containsValue(p))) {
      throw const PatchException(
        'INVALID_PACKAGE',
        'Unreferenced package file',
      );
    }
    return PatchPackage(
      version: envelope.version,
      digest: envelope.sha256,
      entrypoints: entrypoints,
      assetPaths: assets,
      files: files,
      programPath: program,
      programFormat: host.programFormat,
    );
  }
}
