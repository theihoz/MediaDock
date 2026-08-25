part of '../media_control.dart';

class MediaControlApp extends StatelessWidget {
  const MediaControlApp({super.key, this.api, this.bootstrapper});
  final Api? api;
  final ControllerBootstrapper? bootstrapper;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Media Control',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          colorScheme: ColorScheme.dark(
            primary: Color(0xFF0066CC),
            secondary: Color(0xFF00A859),
            surface: Color(0xFF121212),
            onSurface: Color(0xFFE0E0E0),
            surfaceContainerHighest: Color(0xFF1E1E1E),
            onSurfaceVariant: Color(0xFFBBBBBB),
          ),
          textTheme: const TextTheme(
            bodyLarge: TextStyle(fontSize: 16, color: Colors.white70),
            labelLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              textStyle: TextStyle(fontSize: 16),
              backgroundColor: Color(0xFF0066CC),
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
          iconTheme: const IconThemeData(color: Colors.white70),
        ),
        home: MediaShell(api: api, bootstrapper: bootstrapper),
      );
}
