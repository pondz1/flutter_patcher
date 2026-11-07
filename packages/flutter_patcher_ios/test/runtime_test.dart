import 'dart:io';
import 'package:flutter_patcher_ios/compiler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher_ios/src/patch_store.dart';
import 'package:flutter_patcher_ios/src/patch_runtime.dart';
import 'package:flutter_patcher_ios/src/models.dart';
import 'package:flutter_patcher_ios/src/asset_bundle.dart';
import 'package:flutter/services.dart';
import 'fixtures.dart';

void main() {
  late Directory dir;
  PatchStore? store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('patch-runtime-');
  });
  tearDown(() async {
    await store?.close();
    await dir.delete(recursive: true);
  });
  Future<void> install(
    String source, {
    Map<String, List<int>>? assets,
    List<String> titleModes = const [],
  }) async {
    final bytes = compilePatchSources({
      'patch': {'main.dart': source},
    });
    final p = await fixture(
      program: bytes,
      assets: assets,
      overrides: {
        'entrypoints': {
          'title': {
            'library': 'package:patch/main.dart',
            'function': 'title',
            'argumentModes': titleModes,
          },
          'view': {'library': 'package:patch/main.dart', 'function': 'view'},
        },
      },
    );
    store = await PatchStore.open(
      directory: dir,
      host: testHost,
      trustedKeys: {'test': await publicKey()},
    );
    await store!.install(p.bytes, p.envelope);
    await store!.close();
    store = await PatchStore.open(
      directory: dir,
      host: testHost,
      trustedKeys: {'test': await publicKey()},
    );
  }

  test(
    'EVC runtime refuses an authenticated module without rejecting it',
    () async {
      final p = await moduleFixture();
      store = await PatchStore.open(
        directory: dir,
        host: moduleHost,
        trustedKeys: {'test': await publicKey()},
      );
      await store!.install(p.bytes, p.envelope);
      await store!.close();
      store = await PatchStore.open(
        directory: dir,
        host: moduleHost,
        trustedKeys: {'test': await publicKey()},
      );
      await expectLater(
        PatchRuntime.load(store!),
        throwsA(
          isA<PatchException>().having((e) => e.code, 'code', 'INCOMPATIBLE'),
        ),
      );
      expect(store!.blacklist, isEmpty);
      expect(store!.active!.program, moduleProgram);
    },
  );

  testWidgets('loads installed serialized bytecode and renders changed widget', (
    tester,
  ) async {
    final (runtime, widget) = (await tester.runAsync(() async {
      await install(
        "import 'package:flutter/widgets.dart'; String title() => 'new logic'; Widget view() => Text('new widget');",
      );
      final runtime = await PatchRuntime.load(store!);
      expect(await runtime.invoke<String>('title'), 'new logic');
      return (runtime, await runtime.invoke<Widget>('view'));
    }))!;
    await tester.pumpWidget(
      Directionality(textDirection: TextDirection.ltr, child: widget),
    );
    expect(find.text('new widget'), findsOneWidget);
    await runtime.dispose();
  });
  test('wrong return type rejects the generation persistently', () async {
    await install(
      "String title() => 'new logic'; String view() => 'wrong widget';",
    );
    final runtime = await PatchRuntime.load(store!);
    await expectLater(
      runtime.invoke<Widget>('view'),
      throwsA(isA<PatchException>()),
    );
    expect(store!.blacklist, isNotEmpty);
    await expectLater(
      runtime.invoke<String>('title'),
      throwsA(isA<PatchException>()),
    );
    await runtime.dispose();
    await store!.close();
    store = await PatchStore.open(
      directory: dir,
      host: testHost,
      trustedKeys: {'test': await publicKey()},
    );
    expect(store!.active, isNull);
  });
  test(
    'boxes numeric arguments for dynamic parameters according to the manifest',
    () async {
      await install(
        "String title(dynamic value) => value.toString(); String view() => 'unused';",
        titleModes: ['boxed'],
      );
      final runtime = await PatchRuntime.load(store!);
      expect(await runtime.invoke<String>('title', arguments: [42]), '42');
      expect(store!.blacklist, isEmpty);
      await runtime.dispose();
    },
  );
  test('passes List<int> with an unboxed container and boxed elements', () async {
    await install(
      "int title(List<int> values) => values[0] + values[1]; String view() => 'unused';",
      titleModes: ['list'],
    );
    final runtime = await PatchRuntime.load(store!);
    expect(
      await runtime.invoke<int>(
        'title',
        arguments: [
          [3, 4],
        ],
      ),
      7,
    );
    expect(store!.blacklist, isEmpty);
    await runtime.dispose();
  });
  test(
    'nullable numeric parameters receive boxed null and numeric values',
    () async {
      await install(
        "String title(int? value) => value == null ? 'none' : value.toString(); String view() => 'unused';",
        titleModes: ['boxed'],
      );
      final runtime = await PatchRuntime.load(store!);
      expect(await runtime.invoke<String>('title', arguments: [42]), '42');
      expect(await runtime.invoke<String>('title', arguments: [null]), 'none');
      await runtime.dispose();
    },
  );
  test('List<String> elements are boxed for string methods', () async {
    await install(
      "String title(List<String> values) => values[0].toUpperCase(); String view() => 'unused';",
      titleModes: ['list'],
    );
    final runtime = await PatchRuntime.load(store!);
    expect(
      await runtime.invoke<String>(
        'title',
        arguments: [
          ['hello'],
        ],
      ),
      'HELLO',
    );
    expect(store!.blacklist, isEmpty);
    await runtime.dispose();
  });
  test('List<dynamic> elements are boxed for dynamic calls', () async {
    await install(
      "String title(List<dynamic> values) => values[0].toString(); String view() => 'unused';",
      titleModes: ['list'],
    );
    final runtime = await PatchRuntime.load(store!);
    expect(
      await runtime.invoke<String>(
        'title',
        arguments: [
          [42],
        ],
      ),
      '42',
    );
    expect(store!.blacklist, isEmpty);
    await runtime.dispose();
  });
  test(
    'boxed JSON map arguments and caller argument-count failures preserve runtime',
    () async {
      await install(
        "String title(Map<String, dynamic> value) => value['name'].toString(); String view() => 'unused';",
        titleModes: ['boxed'],
      );
      final runtime = await PatchRuntime.load(store!);
      await expectLater(
        runtime.invoke<String>('title'),
        throwsA(
          isA<PatchException>().having((e) => e.code, 'code', 'ARGUMENTS'),
        ),
      );
      expect(
        await runtime.invoke<String>(
          'title',
          arguments: [
            {'name': 'Ada'},
          ],
        ),
        'Ada',
      );
      expect(store!.blacklist, isEmpty);
      await runtime.dispose();
    },
  );
  test('returned JSON maps and lists contain native keys and values', () async {
    await install(
      "Map<String, dynamic> title() => {'names': ['a', 'b'], 'count': 2}; String view() => 'unused';",
    );
    final runtime = await PatchRuntime.load(store!);
    final result = await runtime.invoke<Map<String, dynamic>>('title');
    expect(result, {
      'names': ['a', 'b'],
      'count': 2,
    });
    expect(result['names'], isA<List<dynamic>>());
    await runtime.dispose();
  });
  testWidgets('patched Image.asset reads the authenticated image overlay', (
    tester,
  ) async {
    final (runtime, widget) = (await tester.runAsync(() async {
      await install(
        "import 'package:flutter/widgets.dart'; Widget view() => Image.asset('images/patch_demo.png'); String title() => 'image';",
        assets: {
          'images/patch_demo.png': await File(
            'example/patch/patch_demo.png',
          ).readAsBytes(),
        },
      );
      final runtime = await PatchRuntime.load(store!);
      return (runtime, await runtime.invoke<Widget>('view'));
    }))!;
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: PatchAssetBundle(package: store!.active, fallback: rootBundle),
        child: Directionality(textDirection: TextDirection.ltr, child: widget),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
      if (tester.widget<RawImage>(find.byType(RawImage)).image != null) break;
    }
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await runtime.dispose();
  });
  test('runtime cannot read an undeclared asset', () async {
    await install(
      "import 'package:flutter/widgets.dart'; Widget view() => Image.asset('private.png'); String title() => 'no';",
    );
    final runtime = await PatchRuntime.load(store!);
    await expectLater(
      runtime.invoke<Widget>('view'),
      throwsA(isA<PatchException>()),
    );
    expect(store!.blacklist, isNotEmpty);
    await runtime.dispose();
  });
  test(
    'exceptions after awaiting interpreted Future also reject the generation',
    () async {
      await install(
        "Future<String> title() async { throw Exception('broken'); } String view() => 'unused';",
      );
      final runtime = await PatchRuntime.load(store!);
      await expectLater(
        runtime.invoke<String>('title'),
        throwsA(isA<PatchException>()),
      );
      expect(store!.blacklist, isNotEmpty);
      await runtime.dispose();
    },
  );
}
