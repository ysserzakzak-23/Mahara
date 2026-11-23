import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../features/notifications/data/notification_service.dart';

/// Must be a top-level (or static) function — the platform calls this in a
/// separate isolate when a push arrives while the app is fully backgrounded
/// / terminated. Kept intentionally minimal: by the time the user taps the
/// notification and reopens the app, the in-app notification list
/// (GET /notifications) already has it, so there's nothing else to do here.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

/// Wires the app to Firebase Cloud Messaging: asks for notification
/// permission, obtains this device's FCM token, and registers it with the
/// backend (POST /notifications/devices) so the backend's existing
/// fcm_client.py can actually deliver pushes to it. Call [initialize] once
/// after a successful login (or on startup if already logged in).
class PushNotificationService {
  PushNotificationService({NotificationService? notificationService})
    : _notifications = notificationService ?? NotificationService();

  final NotificationService _notifications;

  Future<void> initialize() async {
    // Firebase is only configured for Android (see firebase_options.dart),
    // so there's nothing to set up on web.
    if (kIsWeb) return;

    try {
      final messaging = FirebaseMessaging.instance;

      await messaging.requestPermission(alert: true, badge: true, sound: true);

      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      final token = await messaging.getToken();
      if (token != null) {
        await _registerToken(token);
      }

      // The token can rotate (app reinstall, token expiry, etc.) — keep the
      // backend's copy in sync whenever that happens.
      FirebaseMessaging.instance.onTokenRefresh.listen(_registerToken);
    } catch (e) {
      // Non-fatal: the app works fine without push notifications.
      debugPrint('Push notification setup failed: $e');
    }
  }

  Future<void> _registerToken(String token) async {
    try {
      await _notifications.registerDevice(
        token,
        deviceLabel: defaultTargetPlatform.name,
      );
    } catch (e) {
      // Non-fatal: push notifications just won't arrive on this device
      // until the next successful registration attempt (e.g. next login).
      debugPrint('Failed to register FCM device token: $e');
    }
  }
}
