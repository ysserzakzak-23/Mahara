import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../core/storage/token_store.dart';
import '../../core/utils/error_text.dart';
import 'data/availability_service.dart';
import 'provider_availability_screen.dart';

/// Run before publishing a service that is NOT remote.
///
/// Customers book those services on a day and hour, so the provider must
/// have working hours. If they have none yet, explains why and opens the
/// working-hours screen; once at least one window is saved the caller can go
/// on publishing. The hours are asked only the first time: afterwards this
/// returns true immediately.
///
/// Returns false when the provider cancels, saves nothing, or the check fails
/// (the reason is shown in a SnackBar).
Future<bool> ensureWorkingHours(
  BuildContext context, {
  TokenStore? tokenStore,
  AvailabilityService? availabilityService,
  Widget Function(int providerId)? availabilityScreenBuilder,
}) async {
  final tokens = tokenStore ?? TokenStore();
  final availability = availabilityService ?? AvailabilityService();
  final messenger = ScaffoldMessenger.of(context);

  try {
    // Whose hours to check. The id comes out of the access token already
    // on the device rather than from /users/me, which was fetched whole
    // for this one field. Null means the token is missing or unreadable:
    // the check simply fails, as it does for any other error here, and
    // nothing is guessed.
    final myId = await tokens.currentUserId;
    if (myId == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text(genericErrorText)),
      );
      return false;
    }

    final existing = await availability.list(myId);
    if (existing.any((w) => w.isActive)) return true;

    if (!context.mounted) return false;
    final wantsToSet = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تحديد أيام وساعات الدوام'),
        content: const Text(
          'هذه الخدمة غير عن بعد، لذلك يجب أن تحدد أولاً أيام وساعات دوامك '
          'ليحجز العملاء ضمنها. تحددها مرة واحدة فقط، وتُستخدم لكل خدماتك القادمة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('تحديد الدوام'),
          ),
        ],
      ),
    );
    if (wantsToSet != true || !context.mounted) return false;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            availabilityScreenBuilder?.call(myId) ??
            ProviderAvailabilityScreen(providerId: myId),
      ),
    );

    final after = await availability.list(myId);
    if (after.any((w) => w.isActive)) return true;

    messenger.showSnackBar(
      const SnackBar(
        content: Text('لم تحدد أي دوام، لا يمكن نشر خدمة غير عن بعد بدونه.'),
      ),
    );
    return false;
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  }
}
