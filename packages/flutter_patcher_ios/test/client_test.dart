import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher_ios/src/patch_client.dart';
import 'package:flutter_patcher_ios/src/patch_store.dart';
import 'package:flutter_patcher_ios/src/models.dart';
import 'fixtures.dart';

void main() {
  late Directory dir;
  late PatchStore store;
  late HttpServer server;
  late Future<void> serverDone;
  Future<void> serve(Future<void> Function(HttpRequest) action) async {
    serverDone = server.forEach((req) async {
      await action(req);
      await req.response.close();
    });
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('patch-client-');
    store = await PatchStore.open(
      directory: dir,
      host: testHost,
      trustedKeys: {'test': await publicKey()},
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });
  tearDown(() async {
    await server.close(force: true);
    await serverDone;
    await store.close();
    await dir.delete(recursive: true);
  });
  Uri getUrl() => Uri.parse('http://127.0.0.1:${server.port}/check');
  test(
    'self-hosted check downloads and stages authenticated code/assets',
    () async {
      final p = await fixture();
      await serve((req) async {
        if (req.uri.path == '/check') {
          req.response.write(
            jsonEncode({
              'hasUpdate': true,
              'patch': {
                ...p.envelope.toJson(),
                'downloadUrl': getUrl().resolve('/patch.zip').toString(),
              },
            }),
          );
        } else {
          req.response.add(p.bytes);
        }
      });
      expect(
        await PatchClient(
          store,
          allowLocalHttp: true,
        ).checkAndInstall(getUrl()),
        isTrue,
      );
      expect(store.pendingVersion, 'fix-1');
      expect(store.active, isNull);
    },
  );
  test('same active digest is not downloaded or staged again', () async {
    final p = await fixture();
    var downloads = 0;
    await serve((req) async {
      if (req.uri.path == '/check') {
        req.response.write(
          jsonEncode({
            'hasUpdate': true,
            'patch': {
              ...p.envelope.toJson(),
              'downloadUrl': getUrl().resolve('/patch.zip').toString(),
            },
          }),
        );
      } else {
        downloads++;
        req.response.add(p.bytes);
      }
    });
    expect(
      await PatchClient(store, allowLocalHttp: true).checkAndInstall(getUrl()),
      isTrue,
    );
    expect(downloads, 1);
    await store.close();
    store = await PatchStore.open(
      directory: dir,
      host: testHost,
      trustedKeys: {'test': await publicKey()},
    );
    await store.confirmBoot();
    expect(store.active?.digest, p.envelope.sha256);
    expect(store.pendingVersion, isNull);

    expect(
      await PatchClient(store, allowLocalHttp: true).checkAndInstall(getUrl()),
      isFalse,
    );
    expect(downloads, 1);
    expect(store.active?.digest, p.envelope.sha256);
    expect(store.pendingVersion, isNull);
    expect(store.diagnostic, 'healthy');
  });
  test('no-update response leaves selection alone', () async {
    await serve((req) async {
      req.response.write('{"hasUpdate":false}');
    });
    expect(
      await PatchClient(store, allowLocalHttp: true).checkAndInstall(getUrl()),
      isFalse,
    );
    expect(store.pendingVersion, isNull);
  });
  test(
    'HTTP is rejected unless explicitly enabled for loopback tests',
    () async {
      await serve((req) async {});
      await expectLater(
        PatchClient(store).checkAndInstall(getUrl()),
        throwsA(isA<PatchException>()),
      );
    },
  );
  test('oversized streamed response is rejected', () async {
    await serve((req) async {
      req.response.write('a' * 2000);
    });
    await expectLater(
      PatchClient(
        store,
        allowLocalHttp: true,
        maxEnvelopeBytes: 1024,
      ).checkAndInstall(getUrl()),
      throwsA(isA<PatchException>()),
    );
  });
  test('HTTP failures never stage a patch', () async {
    await serve((req) async {
      req.response.statusCode = 503;
    });
    await expectLater(
      PatchClient(store, allowLocalHttp: true).checkAndInstall(getUrl()),
      throwsA(isA<PatchException>()),
    );
    expect(store.pendingVersion, isNull);
  });
}
