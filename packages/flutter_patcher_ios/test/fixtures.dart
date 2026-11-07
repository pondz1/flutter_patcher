import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_patcher_ios/src/models.dart';

const testHost = PatchHost(
  appId: 'test.app',
  version: '1.0.0',
  buildNumber: '53.1',
  apiId: 'test-api-1',
  entrypoints: {'title', 'view'},
);
const moduleHost = PatchHost(
  appId: 'test.app',
  version: '1.0.0',
  buildNumber: '53.1',
  apiId: 'test-api-1',
  entrypoints: {'app.main'},
  programFormat: PatchProgramFormat.dartBytecodeV3,
);
final moduleProgram = Uint8List.fromList([
  0x33,
  0x43,
  0x42,
  0x44,
  3,
  0,
  0,
  0,
  17,
  23,
]);
Future<({Uint8List bytes, PatchEnvelope envelope})> moduleFixture({
  Map<String, dynamic>? overrides,
  Uint8List? program,
}) => fixture(
  program: program ?? moduleProgram,
  overrides: {
    'programFormat': 'dart-bytecode-v3',
    'runtimeId': 'dart-ddm-v3/3f287915e06d8f802799c02c333da32e2b7d8dac',
    'entrypoints': {
      'app.main': {
        'library': 'package:app/main.dart',
        'function': 'main',
        'argumentModes': [],
      },
    },
    ...?overrides,
  },
);
final testSeed = List<int>.generate(32, (i) => i);
Future<List<int>> publicKey() async =>
    (await (await Ed25519().newKeyPairFromSeed(
      testSeed,
    )).extractPublicKey()).bytes;

Future<({Uint8List bytes, PatchEnvelope envelope})> fixture({
  String version = 'fix-1',
  Map<String, dynamic>? overrides,
  Uint8List? program,
  Map<String, List<int>>? assets,
  void Function(Archive)? amend,
}) async {
  final contents = <String, List<int>>{
    'code/patch.evc': program ?? [0x45, 0x56, 0x43, 0, 0, 0, 0, 81],
    for (final e
        in (assets ?? {'images/logo.txt': utf8.encode('patched')}).entries)
      'assets/${e.key}': e.value,
  };
  final manifest = <String, dynamic>{
    'schemaVersion': 1,
    'platform': 'ios',
    'version': version,
    'host': testHost.toJson(),
    'runtimeId': iosPatchRuntimeId,
    'program': 'code/patch.evc',
    'entrypoints': {
      'title': {'library': 'package:patch/main.dart', 'function': 'title'},
      'view': {'library': 'package:patch/main.dart', 'function': 'view'},
    },
    'assets': {
      for (final key in (assets ?? {'images/logo.txt': []}).keys)
        key: 'assets/$key',
    },
    'files': {
      for (final e in contents.entries)
        e.key: {
          'size': e.value.length,
          'sha256': sha256.convert(e.value).toString(),
        },
    },
    ...?overrides,
  };
  final zip = Archive();
  for (final e in contents.entries) {
    zip.add(ArchiveFile(e.key, e.value.length, e.value));
  }
  final json = utf8.encode(jsonEncode(manifest));
  zip.add(ArchiveFile('manifest.json', json.length, json));
  amend?.call(zip);
  final bytes = Uint8List.fromList(ZipEncoder().encode(zip));
  return (bytes: bytes, envelope: await signFixture(bytes, version));
}

Future<PatchEnvelope> signFixture(Uint8List bytes, String version) async {
  final digest = sha256.convert(bytes).toString();
  final sig = await Ed25519().sign(
    utf8.encode('flutter_patcher:ios:v1\n$digest'),
    keyPair: await Ed25519().newKeyPairFromSeed(testSeed),
  );
  return PatchEnvelope(
    version: version,
    sha256: digest,
    size: bytes.length,
    keyId: 'test',
    signature: base64Encode(sig.bytes),
    downloadUrl: Uri.parse('https://example.invalid/patch.zip'),
  );
}
