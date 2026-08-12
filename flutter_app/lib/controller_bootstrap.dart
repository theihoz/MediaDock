import 'dart:async';

enum ControllerStartupResult { ready, failed }

typedef ControllerProbe = Future<bool> Function();
typedef ControllerLaunch = Future<void> Function();
typedef ControllerDelay = Future<void> Function(Duration duration);

class ControllerBootstrapper {
  ControllerBootstrapper({
    required this.probe,
    required this.launch,
    ControllerDelay? delay,
    this.attempts = 5,
  }) : delay = delay ?? Future<void>.delayed;

  final ControllerProbe probe;
  final ControllerLaunch launch;
  final ControllerDelay delay;
  final int attempts;
  Future<ControllerStartupResult>? _pending;

  Future<ControllerStartupResult> ensureReady() {
    return _pending ??= _run().whenComplete(() => _pending = null);
  }

  Future<ControllerStartupResult> _run() async {
    if (attempts < 1) return ControllerStartupResult.failed;
    if (await _safeProbe()) return ControllerStartupResult.ready;
    try {
      await launch();
    } catch (_) {
      return ControllerStartupResult.failed;
    }
    for (var index = 1; index < attempts; index++) {
      await delay(Duration(milliseconds: 250 * (1 << (index - 1))));
      if (await _safeProbe()) return ControllerStartupResult.ready;
    }
    return ControllerStartupResult.failed;
  }

  Future<bool> _safeProbe() async {
    try {
      return await probe();
    } catch (_) {
      return false;
    }
  }
}
