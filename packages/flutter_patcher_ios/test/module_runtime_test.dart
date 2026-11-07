import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_patcher_ios/modules.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

class _BundledAssets extends CachingAssetBundle {
  final Uint8List? program;
  _BundledAssets({this.program});

  @override
  Future<ByteData> load(String key) async {
    if (key == 'base.bytecode' && program != null) {
      final padded = Uint8List.fromList([99, 99, ...program!, 99]);
      return ByteData.sublistView(padded, 2, padded.length - 1);
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode('bundled')));
  }
}

void main() {
  late Directory directory;
  late Map<String, List<int>> keys;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('module-runtime-');
    keys = {'test': await publicKey()};
  });

  tearDown(() async => directory.delete(recursive: true));

  Future<PatchStore> open({PatchHost host = moduleHost}) =>
      PatchStore.open(directory: directory, host: host, trustedKeys: keys);

  test(
    'bundled module is loaded once and cannot be replaced in process',
    () async {
      final store = await open();
      final calls = <List<int>>[];
      final runtime = ModulePatchRuntime(
        store,
        loader: (program) async {
          calls.add(program.toList());
          return null;
        },
      );
      try {
        await runtime.run(moduleProgram);
        expect(calls, [moduleProgram.toList()]);
        expect(runtime.hasPatch, isFalse);
        await expectLater(runtime.run(moduleProgram), throwsStateError);
        expect(calls, hasLength(1));
      } finally {
        await runtime.dispose();
        await store.close();
      }
    },
  );

  test(
    'authenticated startup selection takes precedence over bundled bytes',
    () async {
      var store = await open();
      final patch = await moduleFixture();
      await store.install(patch.bytes, patch.envelope);
      await store.close();
      store = await open();
      final calls = <List<int>>[];
      final runtime = ModulePatchRuntime(
        store,
        loader: (program) async {
          calls.add(program.toList());
          return null;
        },
      );
      try {
        await runtime.run(Uint8List.fromList([99]));
        expect(calls, [moduleProgram.toList()]);
        expect(runtime.hasPatch, isTrue);
      } finally {
        await runtime.dispose();
        await store.close();
      }
    },
  );

  test(
    'failed module is quarantined without loading fallback in that isolate',
    () async {
      var store = await open();
      final patch = await moduleFixture();
      await store.install(patch.bytes, patch.envelope);
      await store.close();
      store = await open();
      var calls = 0;
      final runtime = ModulePatchRuntime(
        store,
        loader: (_) async {
          calls++;
          throw StateError('application startup failed');
        },
      );
      final failure = expectLater(runtime.errors, emits(isA<StateError>()));
      try {
        await expectLater(
          runtime.run(moduleProgram),
          throwsA(isA<PatchException>()),
        );
        await failure;
        expect(runtime.failed, isTrue);
        expect(store.blacklist, contains(patch.envelope.sha256));
        await expectLater(runtime.run(moduleProgram), throwsStateError);
        expect(calls, 1);
      } finally {
        await runtime.dispose();
        await store.close();
      }
      store = await open();
      expect(store.active, isNull);
      await store.close();
    },
  );

  test('EVC storage is rejected before a module loader is called', () async {
    final store = await open(host: testHost);
    try {
      expect(() => ModulePatchRuntime(store), throwsA(isA<PatchException>()));
      expect(store.blacklist, isEmpty);
    } finally {
      await store.close();
    }
  });

  test('invalid bundled header never reaches the VM loader', () async {
    final store = await open();
    var calls = 0;
    final runtime = ModulePatchRuntime(
      store,
      loader: (_) async {
        calls++;
        return null;
      },
    );
    try {
      await expectLater(
        runtime.run(Uint8List(8)),
        throwsA(isA<PatchException>()),
      );
      expect(calls, 0);
    } finally {
      await runtime.dispose();
      await store.close();
    }
  });

  test('an application entrypoint returning a value is rejected', () async {
    final store = await open();
    final runtime = ModulePatchRuntime(store, loader: (_) async => 'not void');
    try {
      await expectLater(
        runtime.run(moduleProgram),
        throwsA(isA<PatchException>()),
      );
      expect(runtime.failed, isTrue);
    } finally {
      await runtime.dispose();
      await store.close();
    }
  });

  test(
    'close releases storage after a failing in-flight check and rollback',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requested = Completer<void>();
      final respond = Completer<void>();
      server.listen((request) async {
        requested.complete();
        await respond.future;
        request.response.statusCode = 503;
        await request.response.close();
      });
      final controller = await ModulePatchHost.open(
        directory: directory,
        host: moduleHost,
        trustedKeys: keys,
        apiBase: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        allowLocalHttp: true,
        bundledAssets: _BundledAssets(),
      );
      final check = expectLater(
        controller.checkAndInstall(),
        throwsA(isA<PatchException>()),
      );
      await requested.future;
      final rollback = controller.rollback();
      final closing = controller.close();
      respond.complete();
      try {
        await check;
        await rollback;
        await closing;
        final reopened = await open();
        await reopened.close();
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'staged module assets remain frozen until a new host is opened',
    () async {
      Future<ModulePatchHost> host() => ModulePatchHost.open(
        directory: directory,
        host: moduleHost,
        trustedKeys: keys,
        apiBase: Uri.parse('https://example.invalid/api/v1'),
        bundledAssets: _BundledAssets(),
      );
      var controller = await host();
      expect(await controller.assets.loadString('images/logo.txt'), 'bundled');
      final patch = await moduleFixture();
      await controller.store.install(patch.bytes, patch.envelope);
      expect(await controller.assets.loadString('images/logo.txt'), 'bundled');
      expect(controller.runtime.hasPatch, isFalse);
      await controller.close();
      controller = await host();
      try {
        expect(
          await controller.assets.loadString('images/logo.txt'),
          'patched',
        );
        expect(controller.runtime.hasPatch, isTrue);
        expect(
          controller.checkUrl.queryParameters['runtime_id'],
          iosDartModuleRuntimeId,
        );
        await controller.rollback();
        expect(
          await controller.assets.loadString('images/logo.txt'),
          'patched',
        );
      } finally {
        await controller.close();
      }
      controller = await host();
      expect(await controller.assets.loadString('images/logo.txt'), 'bundled');
      await controller.close();
    },
  );

  test(
    'host is available inside main and only one host enters the isolate',
    () async {
      late ModulePatchHost controller;
      final calls = <List<int>>[];
      controller = await ModulePatchHost.open(
        directory: directory,
        host: moduleHost,
        trustedKeys: keys,
        apiBase: Uri.parse('https://example.invalid/api/v1'),
        bundledAssets: _BundledAssets(program: moduleProgram),
        loader: (program) async {
          expect(ModulePatchHost.current, same(controller));
          calls.add(program.toList());
          return null;
        },
      );
      try {
        await controller.runApplication('base.bytecode');
        expect(calls, [moduleProgram.toList()]);
        await expectLater(
          controller.runApplication('base.bytecode'),
          throwsStateError,
        );
      } finally {
        await controller.close();
      }
      final other = await ModulePatchHost.open(
        directory: directory,
        host: moduleHost,
        trustedKeys: keys,
        apiBase: Uri.parse('https://example.invalid/api/v1'),
        bundledAssets: _BundledAssets(program: moduleProgram),
        loader: (_) async => fail('Second module entered the same isolate'),
      );
      try {
        await expectLater(
          other.runApplication('base.bytecode'),
          throwsStateError,
        );
      } finally {
        await other.close();
      }
    },
  );
}
