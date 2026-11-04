import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher_ios/src/patch_store.dart';
import 'package:flutter_patcher_ios/src/models.dart';
import 'fixtures.dart';

void main() {
  late Directory dir;
  final opened = <PatchStore>[];
  Future<PatchStore> open() async {
    final store = await PatchStore.open(
      directory: dir,
      host: testHost,
      trustedKeys: {'test': await publicKey()},
    );
    opened.add(store);
    return store;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('patch-store-');
  });
  tearDown(() async {
    for (final s in opened) {
      await s.close();
    }
    opened.clear();
    await dir.delete(recursive: true);
  });
  test('install is pending until another process opens the store', () async {
    final p = await fixture();
    final s = await open();
    await s.install(p.bytes, p.envelope);
    expect(s.active, isNull);
    expect(s.pendingVersion, 'fix-1');
    await s.close();
    final next = await open();
    expect(next.active!.version, 'fix-1');
    expect(utf8.decode(next.active!.asset('images/logo.txt')!), 'patched');
    await next.confirmBoot();
    await next.close();
    final offline = await open();
    expect(offline.active!.version, 'fix-1');
  });
  test('explicit failure falls back and refuses the failed payload', () async {
    final p = await fixture();
    final s = await open();
    await s.install(p.bytes, p.envelope);
    await s.close();
    final next = await open();
    await next.reportFailure('bad widget');
    await next.close();
    final recovered = await open();
    expect(recovered.active, isNull);
    expect(recovered.blacklist.values, contains('bad widget'));
    await expectLater(
      recovered.install(p.bytes, p.envelope),
      throwsA(isA<PatchException>()),
    );
  });
  test(
    'reapplying active content is idempotent before boot confirmation',
    () async {
      final p = await fixture();
      final s = await open();
      await s.install(p.bytes, p.envelope);
      await s.close();
      final next = await open();
      await next.install(p.bytes, p.envelope);
      expect(next.active!.version, 'fix-1');
      expect(next.blacklist, isEmpty);
    },
  );
  test(
    'third unconfirmed launch falls back after two interrupted attempts',
    () async {
      final p = await fixture();
      final s = await open();
      await s.install(p.bytes, p.envelope);
      await s.close();
      for (var i = 0; i < 2; i++) {
        final attempt = await open();
        expect(attempt.active, isNotNull);
        await attempt.close();
      }
      final fallback = await open();
      expect(fallback.active, isNull);
      expect(
        fallback.blacklist.values,
        contains('interrupted_launch_threshold'),
      );
    },
  );
  test('manual rollback retains previous healthy code and assets', () async {
    final first = await fixture();
    final second = await fixture(
      version: 'fix-2',
      assets: {'images/logo.txt': utf8.encode('second')},
    );
    final s = await open();
    await s.install(first.bytes, first.envelope);
    await s.close();
    final v1 = await open();
    await v1.confirmBoot();
    await v1.install(second.bytes, second.envelope);
    await v1.close();
    final v2 = await open();
    await v2.confirmBoot();
    await v2.rollback();
    expect(v2.active!.version, 'fix-2');
    await v2.close();
    final reverted = await open();
    expect(reverted.active!.version, 'fix-1');
    expect(utf8.decode(reverted.active!.asset('images/logo.txt')!), 'patched');
    await reverted.confirmBoot();
    await expectLater(
      reverted.install(second.bytes, second.envelope),
      throwsA(isA<PatchException>()),
    );
  });
  test('tampered on-disk package is reverified before execution', () async {
    final p = await fixture();
    final s = await open();
    await s.install(p.bytes, p.envelope);
    await s.close();
    await File(
      '${dir.path}/generations/${p.envelope.sha256}/payload.zip',
    ).writeAsBytes([0]);
    final next = await open();
    expect(next.active, isNull);
    expect(next.blacklist, isNotEmpty);
  });
  test(
    'incomplete selection temp file never overrides last committed state',
    () async {
      final s = await open();
      await s.close();
      await File('${dir.path}/state.next').writeAsString('{"selected":');
      final next = await open();
      expect(next.active, isNull);
      final p = await fixture();
      await next.install(p.bytes, p.envelope);
      await next.close();
      expect((await open()).active!.version, 'fix-1');
    },
  );
  test('rejects a second owner of the same storage directory', () async {
    await open();
    await expectLater(open(), throwsA(isA<PatchException>()));
  });
}
