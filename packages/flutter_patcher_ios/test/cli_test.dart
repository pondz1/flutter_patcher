import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher_ios/src/models.dart';
import 'package:flutter_patcher_ios/src/package_codec.dart';
import 'package:flutter_patcher_ios/src/patch_store.dart';
import 'package:flutter_patcher_ios/src/patch_runtime.dart';
import 'package:flutter_patcher_ios/compiler.dart';
import 'fixtures.dart';

void main() {
  test('pack CLI produces installable signed executable patch', () async {
    final dir = await Directory.systemTemp.createTemp('patch-cli-');
    addTearDown(() => dir.delete(recursive: true));
    await File(
      '${dir.path}/main.dart',
    ).writeAsString("String title() => 'from CLI'; String view() => 'unused';");
    await File('${dir.path}/logo.txt').writeAsString('CLI asset');
    await File(
      '${dir.path}/private.seed',
    ).writeAsString(base64Encode(testSeed));
    final config = {
      'version': 'cli-1',
      'host': testHost.toJson(),
      'program': 'patch.evc',
      'sources': {
        'patch': {'main.dart': 'main.dart'},
      },
      'entrypoints': {
        'title': {'library': 'package:patch/main.dart', 'function': 'title'},
        'view': {'library': 'package:patch/main.dart', 'function': 'view'},
      },
      'assets': {'images/logo.txt': 'logo.txt'},
    };
    final configFile = File('${dir.path}/patch.json');
    await configFile.writeAsString(jsonEncode(config));
    await File('${dir.path}/patch.evc').writeAsBytes(
      compilePatchSources({
        'patch': {
          'main.dart': await File('${dir.path}/main.dart').readAsString(),
        },
      }),
    );
    final pack = await Process.run('dart', [
      '--packages=.dart_tool/package_config.json',
      'bin/pack.dart',
      '--config',
      configFile.path,
      '--seed',
      '${dir.path}/private.seed',
      '--key-id',
      'test',
      '--url',
      'https://cdn.invalid/patch.zip',
      '--out',
      '${dir.path}/dist',
    ]);
    expect(pack.exitCode, 0, reason: '${pack.stdout}\n${pack.stderr}');
    final envelope = PatchEnvelope.fromJson(
      jsonDecode(await File('${dir.path}/dist/envelope.json').readAsString()),
    );
    final bytes = await File('${dir.path}/dist/patch.zip').readAsBytes();
    final package = await PatchPackageCodec(
      host: testHost,
      trustedKeys: {'test': await publicKey()},
    ).verify(bytes, envelope);
    expect(utf8.decode(package.asset('images/logo.txt')!), 'CLI asset');
    final storage = Directory('${dir.path}/storage');
    var store = await PatchStore.open(
      directory: storage,
      host: testHost,
      trustedKeys: {'test': await publicKey()},
    );
    await store.install(bytes, envelope);
    await store.close();
    store = await PatchStore.open(
      directory: storage,
      host: testHost,
      trustedKeys: {'test': await publicKey()},
    );
    final runtime = await PatchRuntime.load(store);
    try {
      expect(await runtime.invoke<String>('title'), 'from CLI');
    } finally {
      await runtime.dispose();
      await store.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
  test('invalid pack invocation fails without creating output files', () async {
    final dir = await Directory.systemTemp.createTemp('patch-cli-invalid-');
    addTearDown(() => dir.delete(recursive: true));
    final result = await Process.run('dart', [
      '--packages=.dart_tool/package_config.json',
      'bin/pack.dart',
      '--out',
      '${dir.path}/dist',
    ]);
    expect(result.exitCode, isNot(0));
    expect(await Directory('${dir.path}/dist').exists(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
