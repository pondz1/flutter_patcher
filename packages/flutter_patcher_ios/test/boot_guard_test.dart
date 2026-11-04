import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_patcher_ios/compiler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher_ios/src/boot_guard.dart';
import 'package:flutter_patcher_ios/src/patch_runtime.dart';
import 'package:flutter_patcher_ios/src/patch_store.dart';
import 'fixtures.dart';

void main() {
  testWidgets(
    'deferred Flutter errors persist rejection and preserve handlers',
    (tester) async {
      final (dir, store, runtime) = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('patch-guard-error-');
        final p = await fixture(
          program: compilePatchSources({
            'patch': {
              'main.dart': "String title() => 'ok'; String view() => 'unused';",
            },
          }),
        );
        var store = await PatchStore.open(
          directory: dir,
          host: testHost,
          trustedKeys: {'test': await publicKey()},
        );
        await store.install(p.bytes, p.envelope);
        await store.close();
        store = await PatchStore.open(
          directory: dir,
          host: testHost,
          trustedKeys: {'test': await publicKey()},
        );
        return (dir, store, await PatchRuntime.load(store));
      }))!;
      final original = FlutterError.onError;
      var forwarded = false;
      void previous(FlutterErrorDetails details) {
        forwarded = true;
      }

      FlutterError.onError = previous;
      try {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: PatchBootGuard(
              runtime: runtime,
              recoveryBuilder: (_, _) => const Text('Restart required'),
              child: const Text('Patched app'),
            ),
          ),
        );
        FlutterError.reportError(
          FlutterErrorDetails(exception: StateError('deferred callback')),
        );
        for (
          var i = 0;
          i < 50 && find.text('Restart required').evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        expect(find.text('Restart required'), findsOneWidget);
        expect(store.blacklist, isNotEmpty);
        expect(forwarded, isTrue);
        await tester.pumpWidget(const SizedBox());
        expect(FlutterError.onError, same(previous));
      } finally {
        FlutterError.onError = original;
        await tester.pumpWidget(const SizedBox());
        await runtime.dispose();
        await tester.runAsync(() async {
          await store.close();
          await dir.delete(recursive: true);
        });
      }
    },
  );
  testWidgets('confirms boot only after five foreground seconds', (
    tester,
  ) async {
    final (dir, store, runtime) = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('patch-guard-');
      final program = compilePatchSources({
        'patch': {
          'main.dart': "String title() => 'ok'; String view() => 'unused';",
        },
      });
      final p = await fixture(program: program);
      var store = await PatchStore.open(
        directory: dir,
        host: testHost,
        trustedKeys: {'test': await publicKey()},
      );
      await store.install(p.bytes, p.envelope);
      await store.close();
      store = await PatchStore.open(
        directory: dir,
        host: testHost,
        trustedKeys: {'test': await publicKey()},
      );
      return (dir, store, await PatchRuntime.load(store));
    }))!;
    final confirmed = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      PatchBootGuard(
        runtime: runtime,
        now: tester.binding.clock.now,
        onBootConfirmed: () => confirmed.complete(),
        recoveryBuilder: (_, _) => const SizedBox(),
        child: const SizedBox(),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 10));
    expect(confirmed.isCompleted, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 2));
    for (var i = 0; i < 50 && !confirmed.isCompleted; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(confirmed.isCompleted, isTrue);
    final state = await tester.runAsync(
      () async =>
          jsonDecode(await File('${dir.path}/state.json').readAsString())
              as Map,
    );
    expect(state!['attempt'], isNull);
    expect(state['healthy'], store.active!.digest);
    await tester.pumpWidget(const SizedBox());
    await runtime.dispose();
    await tester.runAsync(() async {
      await store.close();
      await dir.delete(recursive: true);
    });
  });
}
