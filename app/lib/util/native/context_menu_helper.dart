import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:win32_registry/win32_registry.dart';

final _logger = Logger('ContextMenuHelper');

Future<bool> enableContextMenu() async {
  if (defaultTargetPlatform != TargetPlatform.windows) {
    return false;
  }

  try {
    final String script =
        '''
\$TargetPath = "${Platform.resolvedExecutable}"
\$ShortcutFile = "${_getWindowsFilePath(_windowsFileName)}"
\$WScriptShell = New-Object -ComObject WScript.Shell
\$Shortcut = \$WScriptShell.CreateShortcut(\$ShortcutFile)
\$Shortcut.TargetPath = \$TargetPath
\$Shortcut.Save()
''';
    final result = await Process.run('powershell', ['-Command', script]);
    if (result.stderr != null && result.stderr!.isNotEmpty) {
      throw Exception('Failed to create shortcut: ${result.stderr}');
    }
    _registerWindowsShellVerbs();
    return await File(_getWindowsFilePath(_windowsFileName)).exists();
  } catch (e) {
    _logger.severe('Failed to enable context menu: $e');
    return false;
  }
}

Future<bool> disableContextMenu() async {
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        _unregisterWindowsShellVerbs();
        final file = File(_getWindowsFilePath(_windowsFileName));
        if (await file.exists()) {
          await file.delete();
        }
        return true;
      default:
        return false;
    }
  } catch (e) {
    return false;
  }
}

Future<bool> isContextMenuEnabled() async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return await File(_getWindowsFilePath(_windowsFileName)).exists();
    default:
      return false;
  }
}

const _windowsFileName = 'LocalSend';

String _getWindowsFilePath(String appName) {
  final appData = Platform.environment['APPDATA'];
  return '$appData/Microsoft/Windows/SendTo/$appName.lnk';
}

/// Windows only: if the context menu option is enabled,
/// (re-)registers the right-click entry so it always points to the current executable
/// (e.g. after an update or when the app was moved).
Future<void> refreshContextMenu() async {
  if (defaultTargetPlatform != TargetPlatform.windows) {
    return;
  }
  try {
    if (await isContextMenuEnabled()) {
      _registerWindowsShellVerbs();
    }
  } catch (e) {
    _logger.warning('Failed to refresh context menu', e);
  }
}

/// Right-click entries ("Send with LocalSend") for files and folders.
/// Written to HKEY_CURRENT_USER, so no administrator rights are needed.
const _windowsShellVerbKeys = [
  r'Software\Classes\*\shell\LocalSend',
  r'Software\Classes\Directory\shell\LocalSend',
];

void _registerWindowsShellVerbs() {
  final exe = Platform.resolvedExecutable;
  for (final path in _windowsShellVerbKeys) {
    final verbKey = Registry.currentUser.createKey(path);
    verbKey.createValue(const RegistryValue.string('MUIVerb', 'Send with LocalSend'));
    verbKey.createValue(RegistryValue.string('Icon', '"$exe",0'));
    // Show the entry even when many files are selected (Windows hides it above 15 by default).
    verbKey.createValue(const RegistryValue.string('MultiSelectModel', 'Player'));
    final commandKey = verbKey.createKey('command');
    commandKey.createValue(RegistryValue.string('', '"$exe" "%1"'));
    commandKey.close();
    verbKey.close();
  }
}

void _unregisterWindowsShellVerbs() {
  for (final path in _windowsShellVerbKeys) {
    try {
      Registry.currentUser.deleteKey(path, recursive: true);
    } catch (_) {
      // does not exist
    }
  }
}
