import 'dart:async';
import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'asset_bundle.dart';
import 'runtime_contract.dart';

/// Install once below MaterialApp's builder. Uncaught errors conservatively
/// reject the selected patch and preserve prior Flutter/platform handlers.
/// recoveryBuilder must use bundled resources and offer a user-driven restart.
class PatchBootGuard extends StatefulWidget {
  final PatchExecution runtime;
  final AssetBundle? assets, bundledAssets;
  final Widget child;
  final Widget Function(BuildContext, Object) recoveryBuilder;
  final Duration verifyAfter;
  final DateTime Function() now;
  final VoidCallback? onBootConfirmed;
  const PatchBootGuard({
    super.key,
    required this.runtime,
    this.assets,
    this.bundledAssets,
    required this.child,
    required this.recoveryBuilder,
    this.verifyAfter = const Duration(seconds: 5),
    this.now = DateTime.now,
    this.onBootConfirmed,
  });
  @override
  State<PatchBootGuard> createState() => _PatchBootGuardState();
}

class _PatchBootGuardState extends State<PatchBootGuard>
    with WidgetsBindingObserver {
  late final AssetBundle _bundle, _bundledAssets;
  Timer? _timer;
  StreamSubscription<Object>? _errors;
  Duration _elapsed = Duration.zero;
  DateTime? _resumed;
  Object? _error;
  bool _confirmed = false;
  FlutterExceptionHandler? _previousFlutter;
  bool Function(Object, StackTrace)? _previousPlatform;
  late final FlutterExceptionHandler _flutterHandler;
  late final bool Function(Object, StackTrace) _platformHandler;
  @override
  void initState() {
    super.initState();
    _bundledAssets = widget.bundledAssets ?? rootBundle;
    _bundle =
        widget.assets ??
        PatchAssetBundle(
          package: widget.runtime.store.active,
          fallback: _bundledAssets,
        );
    if (!widget.runtime.hasPatch) return;
    _error = widget.runtime.failed
        ? StateError('Patch already failed; restart required')
        : null;
    _previousFlutter = FlutterError.onError;
    _previousPlatform = PlatformDispatcher.instance.onError;
    _flutterHandler = (details) {
      unawaited(_reject(details.exception));
      (_previousFlutter ?? FlutterError.presentError)(details);
    };
    _platformHandler = (error, stack) {
      unawaited(_reject(error));
      return _previousPlatform?.call(error, stack) ?? false;
    };
    FlutterError.onError = _flutterHandler;
    PlatformDispatcher.instance.onError = _platformHandler;
    _errors = widget.runtime.errors.listen(_showRecovery);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _error != null) return;
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) _resume();
    });
  }

  Future<void> _reject(Object error) async {
    try {
      await widget.runtime.reportFailure(error);
    } catch (persistenceError) {
      _showRecovery(
        StateError('$error (failure persistence: $persistenceError)'),
      );
    }
    _showRecovery(error);
  }

  void _showRecovery(Object error) {
    _timer?.cancel();
    if (!mounted || _error != null) return;
    // FlutterError can be raised while the widget tree is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _error == null) setState(() => _error = error);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _resume() {
    if (_confirmed || _error != null || widget.runtime.failed) return;
    _resumed = widget.now();
    final left = widget.verifyAfter - _elapsed;
    _timer = Timer(left.isNegative ? Duration.zero : left, () async {
      if (!mounted || widget.runtime.failed || _error != null) return;
      try {
        await widget.runtime.store.confirmBoot();
        if (!mounted) return;
        _confirmed = true;
        widget.onBootConfirmed?.call();
      } catch (e) {
        _showRecovery(e);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _timer?.cancel();
      _resume();
    } else {
      if (_resumed != null) {
        _elapsed += widget.now().difference(_resumed!);
        _resumed = null;
      }
      _timer?.cancel();
    }
  }

  @override
  void didUpdateWidget(PatchBootGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.runtime, oldWidget.runtime)) {
      throw StateError(
        'A process must retain one PatchRuntime; restart to select another generation',
      );
    }
  }

  @override
  Widget build(BuildContext context) => DefaultAssetBundle(
    bundle: _error == null ? _bundle : _bundledAssets,
    child: _error == null
        ? widget.child
        : widget.recoveryBuilder(context, _error!),
  );
  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_errors?.cancel());
    if (widget.runtime.hasPatch) {
      WidgetsBinding.instance.removeObserver(this);
      if (identical(FlutterError.onError, _flutterHandler)) {
        FlutterError.onError = _previousFlutter;
      }
      if (identical(PlatformDispatcher.instance.onError, _platformHandler)) {
        PlatformDispatcher.instance.onError = _previousPlatform;
      }
    }
    super.dispose();
  }
}
