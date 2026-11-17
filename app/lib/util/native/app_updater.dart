import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/util/native/windows_notifications.dart';
import 'package:logging/logging.dart';

final _logger = Logger('AppUpdater');

/// The GitHub repository whose releases contain the Windows installer.
const _updateRepository = '3moor111/localsend';

/// Build number of this app, set by the release workflow (`--dart-define=APP_BUILD=<n>`).
/// Local builds have 0 and never update themselves.
const appBuildNumber = int.fromEnvironment('APP_BUILD');

const _checkInterval = Duration(hours: 3);

int _lastNotifiedBuild = 0;
bool _installing = false;

/// Windows only: checks for a new release on start and every few hours.
/// When one exists, a notification asks the user to install it.
void startAppUpdater() {
  if (!Platform.isWindows || appBuildNumber == 0) {
    return;
  }
  // Let the app finish starting first.
  Timer(const Duration(seconds: 20), () {
    // ignore: discarded_futures
    checkForAppUpdate();
    Timer.periodic(_checkInterval, (_) {
      // ignore: discarded_futures
      checkForAppUpdate();
    });
  });
}

Future<void> checkForAppUpdate() async {
  try {
    final release = await _getLatestRelease();
    if (release == null || release.build <= appBuildNumber || release.build == _lastNotifiedBuild) {
      return;
    }
    _lastNotifiedBuild = release.build;
    _logger.info('Update available: build ${release.build} (current: $appBuildNumber)');

    await showWindowsNotification(
      title: 'LocalSend update available',
      body: 'A new version (build ${release.build}) is ready. Install it now?',
      actions: ['Install update'],
      onAction: (_) {
        // ignore: discarded_futures
        _install(release);
      },
    );
  } catch (e) {
    _logger.warning('Update check failed', e);
  }
}

Future<_Release?> _getLatestRelease() async {
  final client = HttpClient()..userAgent = 'LocalSend-Updater';
  try {
    final request = await client.getUrl(Uri.parse('https://api.github.com/repos/$_updateRepository/releases/latest'));
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      _logger.info('Update check returned ${response.statusCode}');
      return null;
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    final match = RegExp(r'^build-(\d+)$').firstMatch(json['tag_name'] as String? ?? '');
    if (match == null) {
      return null;
    }
    final assets = (json['assets'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final installer = assets.where((a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.exe')).firstOrNull;
    if (installer == null) {
      return null;
    }
    return _Release(
      build: int.parse(match.group(1)!),
      downloadUrl: installer['browser_download_url'] as String,
    );
  } finally {
    client.close();
  }
}

Future<void> _install(_Release release) async {
  if (_installing) {
    return;
  }
  _installing = true;
  try {
    await showWindowsNotification(
      title: 'Downloading LocalSend update…',
      body: 'LocalSend will restart when the update is installed.',
      actions: const [],
      onAction: (_) {},
    );

    final file = File('${Directory.systemTemp.path}\\LocalSend-Setup-build-${release.build}.exe');
    final client = HttpClient()..userAgent = 'LocalSend-Updater';
    try {
      final response = await (await client.getUrl(Uri.parse(release.downloadUrl))).close();
      if (response.statusCode != 200) {
        throw Exception('Download failed with status ${response.statusCode}');
      }
      await response.pipe(file.openWrite());
    } finally {
      client.close();
    }

    // Start-Process asks for administrator rights (UAC). If the user declines, LocalSend is started again.
    // After a silent install the installer starts LocalSend itself.
    final exe = Platform.resolvedExecutable.replaceAll("'", "''");
    final setup = file.path.replaceAll("'", "''");
    final script =
        "try { Start-Process -FilePath '$setup' -ArgumentList '/SILENT','/SUPPRESSMSGBOXES','/NORESTART' -Verb RunAs -ErrorAction Stop } "
        "catch { Start-Process -FilePath '$exe' }";
    await Process.start(
      'powershell',
      ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', script],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  } catch (e) {
    _logger.warning('Failed to install update', e);
    _installing = false;
    _lastNotifiedBuild = 0; // offer it again on the next check
    await showWindowsNotification(
      title: 'LocalSend update failed',
      body: 'The update could not be installed. It will be offered again later.',
      actions: const [],
      onAction: (_) {},
    );
  }
}

class _Release {
  final int build;
  final String downloadUrl;

  _Release({required this.build, required this.downloadUrl});
}
