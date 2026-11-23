import 'package:flutter/material.dart';

import '../../core/theme/theme_controller.dart';
import '../../shared/widgets/day_night_switch.dart';

/// The calm red used for «تسجيل الخروج» (menu item and confirm button).
Color logoutColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Colors.red.shade300
    : Colors.red.shade400;

/// The two controls at the top-left (RTL) of «حسابي», side by side:
///  * the day/night switch, wired to [ThemeController] (the app's one theme
///    mechanism: it switches [MaterialApp.themeMode] for the whole app at
///    once and saves the choice in SharedPreferences);
///  * the ⚙️ in the corner, opening a small menu with «تسجيل الخروج», which
///    only calls [onLogout] — the screen asks for confirmation before
///    anything is cleared.
class ProfileHeaderActions extends StatelessWidget {
  const ProfileHeaderActions({super.key, required this.onLogout});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<ThemeMode>(
          valueListenable: ThemeController.mode,
          builder: (context, mode, _) => Tooltip(
            message: 'الوضع الداكن',
            child: DayNightSwitch(
              key: const Key('dark-mode-switch'),
              value: mode == ThemeMode.dark,
              semanticLabel: 'الوضع الداكن',
              onChanged: ThemeController.setDark,
            ),
          ),
        ),
        const SizedBox(width: 4),
        _SettingsMenu(onLogout: onLogout),
      ],
    );
  }
}

/// The ⚙️ and its small pop-up menu (a [MenuAnchor]: built in this
/// widget's own context, so it always follows the current theme).
class _SettingsMenu extends StatelessWidget {
  const _SettingsMenu({required this.onLogout});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final red = logoutColor(context);
    final direction = Directionality.of(context);
    final opposite = direction == TextDirection.rtl
        ? TextDirection.ltr
        : TextDirection.rtl;

    // The ⚙️ sits at the END corner of the app bar (top-left in RTL). A menu
    // laid out in the page's own direction would open past that corner,
    // off-screen, and be pushed flat against the edge; laying the panel out
    // in the opposite direction makes it open toward the inside of the
    // screen. Its content is put back in the page's direction below.
    return Directionality(
      textDirection: opposite,
      child: MenuAnchor(
        alignmentOffset: const Offset(6, 4),
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(6),
          shadowColor: WidgetStatePropertyAll(
            Colors.black.withValues(alpha: dark ? 0.6 : 0.25),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 6),
          ),
        ),
        menuChildren: [
          Directionality(
            textDirection: direction,
            child: MenuItemButton(
              key: const Key('settings-logout'),
              onPressed: onLogout,
              leadingIcon: Icon(Icons.logout_rounded, size: 20, color: red),
              style: MenuItemButton.styleFrom(
                minimumSize: const Size(170, 46),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              child: Text(
                'تسجيل الخروج',
                style: TextStyle(
                  color: red,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
        builder: (context, controller, _) => Directionality(
          textDirection: direction,
          child: IconButton(
            key: const Key('profile-settings'),
            tooltip: 'الإعدادات',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
      ),
    );
  }
}
