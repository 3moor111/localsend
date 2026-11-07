import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

final _logger = Logger('ScreenshotWatcher');

const _imageExtensions = {'.png', '.jpg', '.jpeg', '.bmp', '.gif', '.webp'};

/// Windows only: watches the Screenshots folder(s) and asks the user
/// whether a newly taken screenshot should be sent with LocalSend.
///
/// Covers screenshots that Windows saves as a file:
/// - Win + PrtScn
/// - Snipping Tool / Win + Shift + S (Windows 11 auto-saves to the Screenshots folder by default)
/// - PrtScn when "Use the Print screen key to open screen capture" is enabled (Windows 11 default)
class ScreenshotWatcher extends StatefulWidget {
  final Widget child;

  const ScreenshotWatcher({required this.child, super.key});

  @override
  State<ScreenshotWatcher> createState() => _ScreenshotWatcherState();
}

class _ScreenshotWatcherState extends State<ScreenshotWatcher> {
  final _subscriptions = <StreamSubscription<FileSystemEvent>>[];
  final _handledPaths = <String>{};
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      // ignore: discarded_futures
      _startWatching();
    }
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      // ignore: discarded_futures
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  Future<void> _startWatching() async {
    final dirs = await _findScreenshotDirectories();
    for (final dir in dirs) {
      _logger.info('Watching for screenshots in ${dir.path}');
      _subscriptions.add(
        dir.watch().listen(
          (event) {
            if (event is FileSystemCreateEvent || event is FileSystemMoveEvent) {
              final path = event is FileSystemMoveEvent ? (event.destination ?? event.path) : event.path;
              // ignore: discarded_futures
              _onNewFile(path);
            }
          },
          onError: (Object e) => _logger.warning('Screenshot watcher error', e),
        ),
      );
    }
  }

  Future<void> _onNewFile(String path) async {
    final lower = path.toLowerCase();
    if (!_imageExtensions.any(lower.endsWith)) {
      return;
    }
    if (!_handledPaths.add(lower)) {
      return;
    }

    // Wait until Windows has finished writing the file.
    final file = File(path);
    int lastSize = -1;
    for (int i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (!file.existsSync()) {
        return;
      }
      final size = file.lengthSync();
      if (size > 0 && size == lastSize) {
        break;
      }
      lastSize = size;
    }

    if (_dialogOpen || !mounted) {
      return;
    }

    // The app may be minimized or hidden in the tray.
    await showFromTray();

    final ctx = Routerino.context;
    if (!ctx.mounted) {
      return;
    }

    _dialogOpen = true;
    final send = await showDialog<bool>(
      context: ctx,
      builder: (context) => AlertDialog(
        title: const Text('Screenshot detected'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Do you want to send this screenshot with LocalSend?'),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 400),
              child: Image.file(file, fit: BoxFit.contain),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    _dialogOpen = false;

    if (send != true || !mounted) {
      return;
    }

    final ref = context.ref;
    await ref
        .redux(selectedSendingFilesProvider)
        .dispatchAsync(
          AddFilesAction(
            files: [file],
            converter: CrossFileConverters.convertFile,
          ),
        );
    ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
  }
}

/// Returns the existing Windows screenshot folders.
Future<List<Directory>> _findScreenshotDirectories() async {
  final candidates = <String>{};

  // The real location of the "Screenshots" known folder (can be moved by the user).
  try {
    final result = await Process.run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
      '/v',
      '{B7BEDE81-DF94-4682-A7D8-57A52620B86F}',
    ]);
    final match = RegExp(r'REG_(?:EXPAND_)?SZ\s+(.+)').firstMatch(result.stdout.toString());
    if (match != null) {
      candidates.add(_expandEnv(match.group(1)!.trim()));
    }
  } catch (e) {
    _logger.warning('Could not read Screenshots folder from registry', e);
  }

  final env = Platform.environment;
  final userProfile = env['USERPROFILE'];
  if (userProfile != null) {
    candidates.add('$userProfile\\Pictures\\Screenshots');
  }
  final oneDrive = env['OneDrive'];
  if (oneDrive != null) {
    candidates.add('$oneDrive\\Pictures\\Screenshots');
  }

  final dirs = <Directory>[];
  final seen = <String>{};
  for (final path in candidates) {
    final dir = Directory(path);
    if (dir.existsSync() && seen.add(dir.absolute.path.toLowerCase())) {
      dirs.add(dir);
    }
  }
  return dirs;
}

String _expandEnv(String input) {
  return input.replaceAllMapped(RegExp('%([^%]+)%'), (m) {
    final key = m.group(1)!;
    final value = Platform.environment.entries.where((e) => e.key.toLowerCase() == key.toLowerCase()).firstOrNull?.value;
    return value ?? m.group(0)!;
  });
}
