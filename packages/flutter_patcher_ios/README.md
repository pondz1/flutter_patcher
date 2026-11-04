# flutter_patcher_ios

Experimental, self-hosted code and asset patches for **prepared Flutter
entrypoints**, using a Dart bytecode interpreter. No hosted service or account
is required. This is an optional companion in the flutter_patcher fork; the
root package's Android AOT API and SDK constraints remain separate.

**Host-app and backend integration are not included. Physical iPhone release
verification is outstanding.** Automated host tests exercise signed installation,
serialized code execution, widgets, assets, networking, and rollback.

## What can change

- Supported Dart functions and widgets that the base app explicitly invokes
  through `PatchRuntime`.
- Local Flutter images and JSON/text assets read through `PatchAssetBundle`.
- Code and assets select one generation on the next process start.

This does not replace arbitrary methods already compiled into an AOT app.
Riverpod, GoRouter, custom models, and native plugins are not automatically
interpretable. The initial API accepts primitive/JSON arguments; existing native
SDKs, plugin changes, app icons, launch screens, and Flutter upgrades require a
new full release. The interpreter supports only a subset of Dart/Flutter.

## Install in a future host app

```yaml
dependencies:
  flutter_patcher_ios:
    git:
      url: https://github.com/pondz1/flutter_patcher.git
      ref: feat/ios-interpreted-patches
      path: packages/flutter_patcher_ios
```

The branch must be pushed before another machine can resolve this example.
During local development, use a path dependency to this directory instead.
Ship the runtime and trusted public key in a full base-app release **before**
publishing a patch for it. Current verification SDK: Flutter 3.47.1 / Dart 3.13.1.
The bridge sources and original BSD license are in `vendor/flutter_eval/`.
Compiler and runtime use exactly dart_eval 0.8.5 and the same bridge revision.

## Bootstrap and explicit entrypoints

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_patcher_ios/flutter_patcher_ios.dart';

// In main(), after WidgetsFlutterBinding.ensureInitialized():
final store = await PatchStore.open(
  host: const PatchHost(
    appId: 'com.example.patch_demo',
    version: '1.0.0',
    buildNumber: '1', // exact string from the base build
    apiId: 'demo-api-1',
    entrypoints: {'title', 'view'},
  ),
  trustedKeys: {'release-1': base64Decode(trustedPublicKeyBase64)},
);

final runtime = await PatchRuntime.load(store);
final home = runtime.hasPatch
    ? await runtime.invoke<Widget>('view')
    : const Text('Bundled screen');

runApp(MaterialApp(
  home: home,
  builder: (context, child) => PatchBootGuard(
    runtime: runtime,
    recoveryBuilder: (_, error) => const Center(
      child: Text('Update failed. Close and reopen the app to recover.'),
    ),
    child: child!,
  ),
));
```

Catch setup/invocation failures before `runApp` and start the bundled application
with its bundled assets. The failure is persisted for the next launch. Do not
reuse a failing runtime or build an app with mixed patch/bundled assets.

Pass actual app identity from your base build; the values above are examples. `apiId` versions the host contract and entrypoint meanings.
Only declared entrypoints are accepted. Custom host objects need explicit bridges
and are outside this initial API. Use `runtime.invoke<String>('title',
arguments: ['world'])` for the included title example.

Each entrypoint declares `argumentModes` in the signed config, in parameter
order. Use `raw` for nonnullable `int`, `double`, or `bool` parameters.
Use `list` for a nonnullable `List` parameter: the container stays native and its
elements are recursively boxed (including numeric elements). Use `boxed` for
`String`, JSON `Map<String, dynamic>`, `dynamic`, `Object`, and nullable parameters.
This is determined by the **declared Dart type**, including nullable types,
rather than the value supplied by the host. For example:

```json
{"library":"package:patch/main.dart","function":"title","argumentModes":["boxed"]}
```

An omitted modes list means a zero-argument function. The host must supply
exactly that many arguments. Keep config and function signatures in sync and
test the intended host calls before publishing. Native JSON results use
`Map<String, dynamic>` and `List<dynamic>`; nested interpreter wrappers are
removed. Arbitrary generic collection signatures are not promised; use JSON-shaped
collections or an encoded JSON string at complex host boundaries. `List<int>`,
`List<String>`, and `List<dynamic>` argument behavior is covered by runtime tests.

The guard supplies the asset bundle below MaterialApp's builder and confirms
startup after the first frame plus five foreground seconds. Background time
does not count. It preserves earlier Flutter/platform error handlers and
conservatively rejects the selected patch on uncaught errors while mounted,
including deferred UI callbacks. Recovery UI must use bundled resources.
Install only one guard/runtime for a process.

## Compile and pack on your machine or CI

Run tools from a **source checkout of this companion package**, not inside an
installed dependency's pub cache. `flutter_test` is a developer dependency used
to host the Flutter bridge compiler; it is not part of the application runtime.

```sh
cd packages/flutter_patcher_ios
flutter pub get
dart run bin/compile.dart --config example/patch/patch.json
```

Compilation runs Flutter's headless engine because Flutter bridge registration
imports `dart:ui`. It fails for unsupported code and writes bytecode only after
success. A reserved bootstrap identifies the compiler/runtime combination.
Do not run the compiler from inside another `flutter test` invocation against
the same package; the shared build cache can lock. CI should compile, then test
as separate sequential commands.

Edit `example/patch/patch.json` to name the exact base app, version, build string,
host API, declared functions, source files, and overlay assets. File paths in the
config resolve relative to that config file. The examples are fixtures only.

Create a 32-byte Ed25519 seed once and keep it private:

```sh
umask 077
openssl rand -base64 32 > /secure/path/ios-patch.seed

dart run bin/pack.dart \
  --config example/patch/patch.json \
  --seed /secure/path/ios-patch.seed \
  --key-id release-1 \
  --url https://your-server.example/patches/demo-fix-1/patch.zip \
  --out dist/demo-fix-1
```

Choose a new output directory each time. Outputs:

- `patch.zip`: authenticated manifest, bytecode, and explicitly listed assets.
- `envelope.json`: metadata for programmatic installation.
- `check.json`: ready-to-serve update-check JSON.
- `trusted-key.json`: base64 public key to embed in the base app.

Never upload the private seed. The packer verifies its own output with the same
consumer verifier before committing release artifacts. It does not upload or
publish anything.

## Self-hosted delivery

Upload `patch.zip` and serve `check.json` from your own HTTPS server or CDN.
For no update, serve `{"hasUpdate":false}`. For an update, serve
`{"hasUpdate":true,"patch":<the envelope.json object>}`.

After the first frame, without blocking launch:

```dart
final installed = await PatchClient(store).checkAndInstall(
  Uri.parse('https://your-server.example/patches/check.json'),
);
// installed means staged. The running generation does not change.
// It takes effect after the user closes and reopens the app process.
```

Wait for the current patched boot to confirm before installing another patch.
If you own the download flow, call `store.install(bytes, envelope)` directly.
HTTPS, payload size, SHA-256, Ed25519 signature, complete file inventory, and
exact host/runtime/API identity are validated. Check and payload headers are
separate; redirect credentials are stripped when the origin changes. Local
loopback HTTP is available only with `allowLocalHttp: true` for testing.

This package does not implement an application backend. A host integration
must keep forced native/full-app upgrades distinct from Dart patches.

## Assets and recovery

Use `PatchAssetBundle(package: store.active, fallback: rootBundle)` explicitly for
non-widget loads. `DefaultAssetBundle.of(context)` and `Image.asset` beneath the
guard use the same selected overlay. Direct `rootBundle.load()` calls continue
to read bundled files. Existing resolution variants are preserved; overlaid/new
`2.0x`-style image paths are merged into `AssetManifest.bin`.

The runtime permits image lookups for packaged assets only. It grants no network,
filesystem, process, or platform-channel permissions to interpreted code. This
is a permission boundary, not a guarantee against infinite loops or all VM bugs.

```dart
await store.rollback(); // previous healthy patch, or bundled app, next start
```

Manual rollback suppresses reapplication of the same content digest. A detected
runtime failure blacklists it. Two consecutive unconfirmed launches cause
fallback on the third launch; these are recorded as interrupted launches, not
proven native crashes. The guard or an explicit `store.confirmBoot()` establishes
a healthy generation. Active code/assets stay immutable until restart.

State changes use atomic rename and a directory owner lock. Stored ZIPs are
reverified on every launch. Use a dedicated app-private storage directory; only
one store may own it. Old generation ZIPs are retained; account for their storage
when operating a long-lived deployment. Offline devices retain their valid
local generation. Disabling server delivery does not remotely erase an offline
device's current patch.

Default limits: 25 MiB compressed ZIP, 100 MiB expanded total, 20 MiB per file,
10,000 entries. The ZIP subset is regular files, STORED or DEFLATE, without
encryption or streaming data descriptors; use the included packer. Patches use
a new iOS schema; Android schema-2 ZIPs and raw
`libapp.so` are rejected. Signed delivery does not itself guarantee App Store
acceptance of every update or usage.

## Verification

```sh
flutter analyze --no-pub
flutter test --no-pub --concurrency 1
cd vendor/flutter_eval
flutter test --no-pub --concurrency 1
```

Before production use, verify a release base app and separate patch on a physical
iPhone: changed Dart function, widget and image/JSON assets, cold start, offline
start, manual rollback, and failed-start recovery. These device checks have not
been performed by the current implementation work.
