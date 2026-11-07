import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher_ios/core.dart';
import 'fixtures.dart';

void main() {
  late PatchPackageCodec codec;
  setUp(() async {
    codec = PatchPackageCodec(
      host: testHost,
      trustedKeys: {'test': await publicKey()},
    );
  });
  test('accepts signed code and assets bound to exact host identity', () async {
    final p = await fixture();
    final verified = await codec.verify(p.bytes, p.envelope);
    expect(verified.version, 'fix-1');
    expect(utf8.decode(verified.asset('images/logo.txt')!), 'patched');
    expect(verified.program, [0x45, 0x56, 0x43, 0, 0, 0, 0, 81]);
  });
  for (final format in ['dart-bytecode-v3', 'unknown', '', 3, false, null]) {
    test(
      'rejects EVC signed with incompatible explicit format $format',
      () async {
        final p = await fixture(overrides: {'programFormat': format});
        await expectLater(
          codec.verify(p.bytes, p.envelope),
          throwsA(
            isA<PatchException>().having((e) => e.code, 'code', 'INCOMPATIBLE'),
          ),
        );
      },
    );
  }
  test('explicit legacy EVC format remains compatible', () async {
    final p = await fixture(overrides: {'programFormat': 'evc-v81'});
    expect(
      (await codec.verify(p.bytes, p.envelope)).programFormat,
      PatchProgramFormat.evc,
    );
    expect(testHost.runtimeId, 'dart_eval-0.8.5/flutter_eval-0.8.2-fp.1');
  });
  test('module host authenticates signed module code and assets', () async {
    final p = await moduleFixture();
    final verified = await PatchPackageCodec(
      host: moduleHost,
      trustedKeys: {'test': await publicKey()},
    ).verify(p.bytes, p.envelope);
    expect(verified.programFormat, PatchProgramFormat.dartBytecodeV3);
    expect(verified.program, [0x33, 0x43, 0x42, 0x44, 3, 0, 0, 0, 17, 23]);
    expect(verified.entrypoints.keys, ['app.main']);
    expect(verified.entrypoints['app.main']!.argumentModes, isEmpty);
    expect(utf8.decode(verified.asset('images/logo.txt')!), 'patched');
    expect(moduleHost.toJson(), {
      'appId': 'test.app',
      'version': '1.0.0',
      'buildNumber': '53.1',
      'apiId': 'test-api-1',
    });
  });
  test('EVC host rejects a valid signed module package', () async {
    final p = await moduleFixture();
    await expectLater(
      codec.verify(p.bytes, p.envelope),
      throwsA(
        isA<PatchException>().having((e) => e.code, 'code', 'INCOMPATIBLE'),
      ),
    );
  });
  test('module host rejects valid signed legacy EVC', () async {
    final p = await fixture();
    await expectLater(
      PatchPackageCodec(
        host: moduleHost,
        trustedKeys: {'test': await publicKey()},
      ).verify(p.bytes, p.envelope),
      throwsA(
        isA<PatchException>().having((e) => e.code, 'code', 'INCOMPATIBLE'),
      ),
    );
  });
  test(
    'module format cannot be inferred from matching bytes and runtime',
    () async {
      final p = await fixture(
        program: moduleProgram,
        overrides: {
          'runtimeId': 'dart-ddm-v3/3f287915e06d8f802799c02c333da32e2b7d8dac',
          'entrypoints': {
            'app.main': {
              'library': 'package:app/main.dart',
              'function': 'main',
            },
          },
        },
      );
      await expectLater(
        PatchPackageCodec(
          host: moduleHost,
          trustedKeys: {'test': await publicKey()},
        ).verify(p.bytes, p.envelope),
        throwsA(
          isA<PatchException>().having((e) => e.code, 'code', 'INCOMPATIBLE'),
        ),
      );
    },
  );
  test(
    'module rejects extra entrypoints even when the host declares them',
    () async {
      const host = PatchHost(
        appId: 'test.app',
        version: '1.0.0',
        buildNumber: '53.1',
        apiId: 'test-api-1',
        entrypoints: {'app.main', 'other'},
        programFormat: PatchProgramFormat.dartBytecodeV3,
      );
      final p = await moduleFixture(
        overrides: {
          'entrypoints': {
            'app.main': {
              'library': 'package:app/main.dart',
              'function': 'main',
            },
            'other': {'library': 'package:app/main.dart', 'function': 'other'},
          },
        },
      );
      await expectLater(
        PatchPackageCodec(
          host: host,
          trustedKeys: {'test': await publicKey()},
        ).verify(p.bytes, p.envelope),
        throwsA(
          isA<PatchException>().having((e) => e.code, 'code', 'INCOMPATIBLE'),
        ),
      );
    },
  );
  test('module rejects explicit null argument modes', () async {
    final p = await moduleFixture(
      overrides: {
        'entrypoints': {
          'app.main': {
            'library': 'package:app/main.dart',
            'function': 'main',
            'argumentModes': null,
          },
        },
      },
    );
    await expectLater(
      PatchPackageCodec(
        host: moduleHost,
        trustedKeys: {'test': await publicKey()},
      ).verify(p.bytes, p.envelope),
      throwsA(isA<PatchException>()),
    );
  });
  for (final overrides in <Map<String, dynamic>>[
    {'programFormat': null},
    {'programFormat': 'evc-v81'},
    {'programFormat': 'unknown'},
    {'runtimeId': iosPatchRuntimeId},
    {'runtimeId': 'other-ddm-runtime'},
    {'entrypoints': <String, dynamic>{}},
    {
      'entrypoints': {
        'other': {'library': 'package:app/main.dart', 'function': 'main'},
      },
    },
    {
      'entrypoints': {
        'app.main': {'library': '', 'function': 'main'},
      },
    },
    {
      'entrypoints': {
        'app.main': {'library': 'package:app/main.dart', 'function': ''},
      },
    },
    {
      'entrypoints': {
        'app.main': {
          'library': 'package:app/main.dart',
          'function': 'main',
          'argumentModes': ['boxed'],
        },
      },
    },
    {
      'entrypoints': {
        'app.main': {'library': 'package:app/main.dart', 'function': 'main'},
        'other': {'library': 'package:app/main.dart', 'function': 'other'},
      },
    },
  ]) {
    test('module contract rejects signed override $overrides', () async {
      final p = await moduleFixture(overrides: overrides);
      await expectLater(
        PatchPackageCodec(
          host: moduleHost,
          trustedKeys: {'test': await publicKey()},
        ).verify(p.bytes, p.envelope),
        throwsA(isA<PatchException>()),
      );
    });
  }
  for (final program in <List<int>>[
    [0x45, 0x56, 0x43, 0, 0, 0, 0, 81],
    [0x33, 0x43, 0x42, 0x44, 0, 0, 0, 3],
    [0x33, 0x43, 0x42, 0x44, 4, 0, 0, 0],
    [0x33, 0x43, 0x42, 0x44, 3, 0, 0],
    [0x32, 0x43, 0x42, 0x44, 3, 0, 0, 0],
  ]) {
    test('module host rejects signed wrong header $program', () async {
      final p = await moduleFixture(program: Uint8List.fromList(program));
      await expectLater(
        PatchPackageCodec(
          host: moduleHost,
          trustedKeys: {'test': await publicKey()},
        ).verify(p.bytes, p.envelope),
        throwsA(
          isA<PatchException>().having((e) => e.code, 'code', 'INCOMPATIBLE'),
        ),
      );
    });
  }
  test('module verification still rejects forged signature', () async {
    final p = await moduleFixture();
    final envelope = PatchEnvelope.fromJson(
      p.envelope.toJson()..['signature'] = base64Encode(List.filled(64, 0)),
    );
    await expectLater(
      PatchPackageCodec(
        host: moduleHost,
        trustedKeys: {'test': await publicKey()},
      ).verify(p.bytes, envelope),
      throwsA(isA<PatchException>().having((e) => e.code, 'code', 'SIGNATURE')),
    );
  });
  test('altered payload is rejected before opening ZIP', () async {
    final p = await fixture();
    p.bytes[0] ^= 1;
    await expectLater(
      codec.verify(p.bytes, p.envelope),
      throwsA(isA<PatchException>()),
    );
  });
  test('verification owns a snapshot of the caller buffer', () async {
    final p = await fixture();
    final pending = codec.verify(p.bytes, p.envelope);
    p.bytes[0] ^= 1;
    expect((await pending).version, 'fix-1');
  });
  test('rejects signed bytes that are not current EVC bytecode', () async {
    final p = await fixture(program: Uint8List.fromList([1, 2, 3]));
    await expectLater(
      codec.verify(p.bytes, p.envelope),
      throwsA(isA<PatchException>()),
    );
  });
  test('rejects unsupported streaming ZIP descriptors before decoding', () async {
    // Ordinary nonseekable Python zipfile output, kept as an independent fixture.
    final bytes = await File('test/fixtures/streaming.zip').readAsBytes();
    await expectLater(
      codec.verify(bytes, await signFixture(bytes, 'fix-1')),
      throwsA(
        isA<PatchException>().having((e) => e.code, 'code', 'UNSUPPORTED_ZIP'),
      ),
    );
  });
  test('rejects a valid ZIP signed by an untrusted key', () async {
    final p = await fixture();
    final json = p.envelope.toJson()..['keyId'] = 'unknown';
    await expectLater(
      codec.verify(p.bytes, PatchEnvelope.fromJson(json)),
      throwsA(isA<PatchException>()),
    );
  });
  test('rejects invalid signature even when payload hash matches', () async {
    final p = await fixture();
    final json = p.envelope.toJson()
      ..['signature'] = base64Encode(List.filled(64, 0));
    await expectLater(
      codec.verify(p.bytes, PatchEnvelope.fromJson(json)),
      throwsA(isA<PatchException>()),
    );
  });
  for (final entry in <String, dynamic>{
    'platform': 'android',
    'runtimeId': 'other-runtime',
    'schemaVersion': 2,
    'host': {...testHost.toJson(), 'buildNumber': '53'},
    'entrypoints': {
      'undeclared': {'library': 'package:p/a.dart', 'function': 'main'},
    },
  }.entries) {
    test('rejects incompatible ${entry.key}', () async {
      final p = await fixture(overrides: {entry.key: entry.value});
      await expectLater(
        codec.verify(p.bytes, p.envelope),
        throwsA(isA<PatchException>()),
      );
    });
  }
  for (final path in ['../escape', '/absolute', 'a\\b', 'a/./b', 'a//b']) {
    test('rejects signed archive with unsafe path $path', () async {
      final p = await fixture(
        amend: (zip) => zip.add(ArchiveFile(path, 1, [1])),
      );
      await expectLater(
        codec.verify(p.bytes, p.envelope),
        throwsA(isA<PatchException>()),
      );
    });
  }
  test('rejects unlisted archive content', () async {
    final p = await fixture(
      amend: (zip) => zip.add(ArchiveFile('extra', 1, [1])),
    );
    await expectLater(
      codec.verify(p.bytes, p.envelope),
      throwsA(isA<PatchException>()),
    );
  });
  test('rejects duplicate central directory paths', () async {
    final p = await fixture(
      amend: (zip) => zip.add(ArchiveFile('code/other.evc', 1, [1])),
    );
    final source = utf8.encode('code/other.evc'),
        replacement = utf8.encode('code/patch.evc');
    final bytes = Uint8List.fromList(p.bytes);
    for (var i = 0; i <= bytes.length - source.length; i++) {
      if (List.generate(
        source.length,
        (j) => bytes[i + j] == source[j],
      ).every((v) => v)) {
        bytes.setRange(i, i + source.length, replacement);
      }
    }
    await expectLater(
      codec.verify(bytes, await signFixture(bytes, 'fix-1')),
      throwsA(isA<PatchException>()),
    );
  });
  test(
    'rejects expanded-size limit even for highly compressible data',
    () async {
      final p = await fixture(assets: {'bomb': List.filled(2000, 0)});
      final bounded = PatchPackageCodec(
        host: testHost,
        trustedKeys: {'test': await publicKey()},
        limits: const PatchLimits(maxFileBytes: 1024),
      );
      await expectLater(
        bounded.verify(p.bytes, p.envelope),
        throwsA(isA<PatchException>()),
      );
    },
  );
  test('rejects signed file digest mismatch', () async {
    final p = await fixture(
      overrides: {
        'files': {
          'code/patch.evc': {'size': 3, 'sha256': '0' * 64},
          'assets/images/logo.txt': {'size': 7, 'sha256': '0' * 64},
        },
      },
    );
    await expectLater(
      codec.verify(p.bytes, p.envelope),
      throwsA(isA<PatchException>()),
    );
  });
}
