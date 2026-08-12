import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/controller_bootstrap.dart';

void main() {
  test('launches the controller once and retries until it is ready', () async {
    var probes = 0;
    var launches = 0;
    final bootstrapper = ControllerBootstrapper(
      probe: () async => ++probes >= 3,
      launch: () async => launches++,
      delay: (_) async {},
      attempts: 4,
    );

    expect(await bootstrapper.ensureReady(), ControllerStartupResult.ready);
    expect(launches, 1);
    expect(probes, 3);
  });

  test('deduplicates concurrent startup attempts', () async {
    var launches = 0;
    var probes = 0;
    final bootstrapper = ControllerBootstrapper(
      probe: () async => ++probes >= 2,
      launch: () async => launches++,
      delay: (_) async {},
      attempts: 3,
    );

    final results = await Future.wait([
      bootstrapper.ensureReady(),
      bootstrapper.ensureReady(),
    ]);

    expect(results, everyElement(ControllerStartupResult.ready));
    expect(launches, 1);
  });

  test('returns failed after bounded retries', () async {
    var probes = 0;
    final bootstrapper = ControllerBootstrapper(
      probe: () async { probes++; return false; },
      launch: () async {},
      delay: (_) async {},
      attempts: 2,
    );

    expect(await bootstrapper.ensureReady(), ControllerStartupResult.failed);
    expect(probes, 2);
  });
}
