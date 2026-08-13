import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/main.dart';

void main() {
  test('parses the UTF-8 BOM written by Windows PowerShell', () {
    final config = LocalConfig.parse(
      '\uFEFF{"gateway":"http://localhost:3000","controller":"http://127.0.0.1:3210","token":"local-token","controllerLauncher":"C:\\\\Media\\\\start.ps1"}',
    );

    expect(config.token, 'local-token');
    expect(config.controllerLauncher, r'C:\Media\start.ps1');
  });
}
