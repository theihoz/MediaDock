import 'dart:io';

class ServerLifecycle {
  Future<void> start() => _run(r'D:\WSL\Start-MediaServer.ps1');
  Future<void> stop() => _run(r'D:\WSL\Stop-MediaServer.ps1');
  Future<void> update() => _run(r'D:\WSL\Update-MediaServer.ps1');

  Future<void> _run(String script) async {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        [script],
        'Lệnh server thất bại',
        result.exitCode,
      );
    }
  }
}
