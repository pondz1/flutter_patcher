import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher_ios/src/models.dart';
import 'package:flutter_patcher_ios/src/package_codec.dart';
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
