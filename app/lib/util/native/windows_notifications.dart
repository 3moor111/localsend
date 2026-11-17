import 'dart:io';

import 'package:local_notifier/local_notifier.dart';
import 'package:logging/logging.dart';

final _logger = Logger('WindowsNotifications');

/// Must match the AppUserModelID of the Start Menu shortcut created by the installer
/// (see support/scripts/compile_windows_exe-inno.iss), otherwise Windows drops the notifications.
const windowsAppUserModelId = 'LocalSend';

bool _ready = false;

/// Whether Windows toast notifications can be shown.
bool get windowsNotificationsReady => _ready;

Future<void> initWindowsNotifications() async {
  if (!Platform.isWindows) {
    return;
  }
  try {
    await localNotifier.setup(
      appName: windowsAppUserModelId,
      shortcutPolicy: ShortcutPolicy.ignore,
    );
    _ready = true;
  } catch (e) {
    _logger.warning('Failed to initialize Windows notifications', e);
  }
}

/// Shows a Windows notification with buttons.
/// [onAction] is called with the index of the clicked button, or `-1` when the notification itself was clicked.
/// Returns `false` if the notification could not be shown.
Future<bool> showWindowsNotification({
  required String title,
  required String body,
  required List<String> actions,
  required void Function(int action) onAction,
}) async {
  if (!_ready) {
    return false;
  }
  try {
    final notification = LocalNotification(
      title: title,
      body: body,
      actions: [for (final a in actions) LocalNotificationAction(text: a)],
    );
    notification.onClick = () => onAction(-1);
    notification.onClickAction = onAction;
    await localNotifier.notify(notification);
    return true;
  } catch (e) {
    _logger.warning('Failed to show notification', e);
    return false;
  }
}
