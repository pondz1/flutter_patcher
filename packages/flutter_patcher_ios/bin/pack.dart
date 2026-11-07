import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_patcher_ios/src/models.dart';
import 'package:flutter_patcher_ios/src/package_codec.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('config')
    ..addOption('seed')
    ..addOption('key-id')
    ..addOption('url')
    ..addOption('out', defaultsTo: 'dist-ios')
    ..addFlag('help', negatable: false);
  Directory? staging;
  try {
    final args = parser.parse(arguments);
    if (args['help'] as bool) {
      stdout.writeln(parser.usage);
      return;
    }
    if (args.rest.isNotEmpty) {
      throw const FormatException('Unexpected positional arguments');
    }
    String option(String name) {
      final value = args[name] as String?;
      if (value == null || value.isEmpty) {
        throw FormatException('--$name is required');
      }
      return value;
    }

    final configFile = File(option('config')).absolute;
    final config = objectMap(jsonDecode(await configFile.readAsString()));
    final seed = base64Decode(
      (await File(option('seed')).readAsString()).trim(),
    );
    if (seed.length != 32) {
      throw const FormatException(
        'Seed file must contain base64 of exactly 32 bytes',
      );
    }
    final keyId = option('key-id');
    final url = Uri.parse(option('url'));
    if (url.scheme != 'https' || url.host.isEmpty || url.userInfo.isNotEmpty) {
      throw const FormatException('--url must be an HTTPS payload URL');
    }
    final output = Directory(option('out')).absolute;
    if (await FileSystemEntity.type(output.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FormatException(
        'Output directory already exists; choose a new --out',
      );
    }
    const limits = PatchLimits();
    final files = <String, List<int>>{};
    Future<void> read(String key, String path) async {
      final file = File.fromUri(configFile.uri.resolve(path));
      if (await file.length() > limits.maxFileBytes) {
        throw const FormatException('Input file too large');
      }
      files[key] = await file.readAsBytes();
    }

    final formatName = config.containsKey('programFormat')
        ? config['programFormat']
        : 'evc-v81';
    final format = switch (formatName) {
      'evc-v81' => PatchProgramFormat.evc,
      'dart-bytecode-v3' => PatchProgramFormat.dartBytecodeV3,
      _ => throw const FormatException('Unsupported programFormat'),
    };
    final programPath = format == PatchProgramFormat.evc
        ? 'code/patch.evc'
        : 'code/patch.dill';
    // Both formats arrive already compiled. Module bytes never enter EVC tools.
    await read(programPath, requiredString(config, 'program'));
    final assets = <String, String>{};
    for (final asset in objectMap(config['assets']).entries) {
      validatePatchPath(asset.key);
      if (asset.value is! String) {
        throw const FormatException('Expected asset input path');
      }
      final path = 'assets/${asset.key}';
      await read(path, asset.value as String);
      assets[asset.key] = path;
    }
    final hostJson = objectMap(config['host']);
    final entries = objectMap(config['entrypoints']);
    final host = PatchHost(
      appId: requiredString(hostJson, 'appId'),
      version: requiredString(hostJson, 'version'),
      buildNumber: requiredString(hostJson, 'buildNumber'),
      apiId: requiredString(hostJson, 'apiId'),
      entrypoints: entries.keys.toSet(),
      programFormat: format,
    );
    final manifest = {
      'schemaVersion': 1,
      'platform': 'ios',
      'version': requiredString(config, 'version'),
      'runtimeId': host.runtimeId,
      if (config.containsKey('programFormat')) 'programFormat': formatName,
      'host': host.toJson(),
      'program': programPath,
      'entrypoints': entries,
      'assets': assets,
      'files': {
        for (final e in files.entries)
          e.key: {
            'size': e.value.length,
            'sha256': hash.sha256.convert(e.value).toString(),
          },
      },
    };
    final zip = Archive();
    for (final e in files.entries) {
      zip.add(ArchiveFile(e.key, e.value.length, e.value));
    }
    final json = utf8.encode(jsonEncode(manifest));
    zip.add(ArchiveFile('manifest.json', json.length, json));
    final bytes = Uint8List.fromList(ZipEncoder().encode(zip));
    final digest = hash.sha256.convert(bytes).toString();
    final algorithm = Ed25519();
    final key = await algorithm.newKeyPairFromSeed(seed);
    final publicKey = await key.extractPublicKey();
    final signature = await algorithm.sign(
      patchSigningMessage(digest),
      keyPair: key,
    );
    final envelope = PatchEnvelope(
      version: manifest['version'] as String,
      sha256: digest,
      size: bytes.length,
      keyId: keyId,
      signature: base64Encode(signature.bytes),
      downloadUrl: url,
    );
    // Use the consumer's real verifier before writing any release artifacts.
    await PatchPackageCodec(
      host: host,
      trustedKeys: {keyId: publicKey.bytes},
    ).verify(bytes, envelope);
    await output.parent.create(recursive: true);
    staging = await output.parent.createTemp('.ios-patch-');
    await File('${staging.path}/patch.zip').writeAsBytes(bytes, flush: true);
    await File(
      '${staging.path}/envelope.json',
    ).writeAsString(jsonEncode(envelope.toJson()), flush: true);
    await File('${staging.path}/check.json').writeAsString(
      jsonEncode({'hasUpdate': true, 'patch': envelope.toJson()}),
      flush: true,
    );
    await File('${staging.path}/trusted-key.json').writeAsString(
      jsonEncode({keyId: base64Encode(publicKey.bytes)}),
      flush: true,
    );
    await staging.rename(output.path);
    stdout.writeln('Wrote signed iOS patch to ${output.path}');
  } catch (e) {
    stderr.writeln('pack failed: $e');
    exitCode = 64;
  } finally {
    if (staging != null && await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }
}
