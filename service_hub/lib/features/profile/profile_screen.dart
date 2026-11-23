import 'package:flutter/material.dart';
import 'package:service_hub/features/profile/edit_profile_screen.dart';

import '../../core/api/api_exception.dart';
import '../../core/config/api_config.dart';
import '../../shared/widgets/full_screen_image_viewer.dart';
import '../admin/admin_dashboard_screen.dart';
import '../auth/data/auth_models.dart';
import '../auth/data/auth_service.dart';
import '../auth/login_screen.dart';
import 'profile_header_actions.dart';
import '../availability/provider_availability_screen.dart';
import '../service/data/catalog_service.dart';
import '../service/data/service_models.dart';
import '../service/add_service_screen.dart';
import '../service/edit_service_screen.dart';
import '../service/service_portfolio_screen.dart';
import '../../core/utils/error_text.dart';
import '../../core/utils/image_sizing.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    this.authService,
    this.catalogService,
    this.addServiceBuilder,
    this.availabilityBuilder,
    this.adminBuilder,
    this.editProfileBuilder,
    this.editServiceBuilder,
    this.portfolioBuilder,
    this.loginBuilder,
  });

  /// Optional overrides, mainly so widget tests can inject a fake backend and
  /// stand-in destination screens. In the real app all are null.
  final AuthService? authService;
  final CatalogService? catalogService;
  final WidgetBuilder? addServiceBuilder;
  final Widget Function(int providerId)? availabilityBuilder;
  final WidgetBuilder? adminBuilder;
  final Widget Function(AppUser user)? editProfileBuilder;
  final Widget Function(int serviceId)? editServiceBuilder;
  final Widget Function(int serviceId, String serviceTitle)? portfolioBuilder;
  final WidgetBuilder? loginBuilder;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final AuthService _authService = widget.authService ?? AuthService();
  late final CatalogService _catalog =
      widget.catalogService ?? CatalogService();
  AppUser? _user;
  List<ServiceListItem> _services = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = await _authService.currentUser();
      List<ServiceListItem> services = [];
      try {
        services = await _catalog.servicesByProvider(user.id);
      } catch (_) {
        // Non-provider users simply have no services.
      }
      if (!mounted) return;
      setState(() {
        _user = user;
        _services = services;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Item: "صفحة المستخدم (حذف خدمة)" — lets a user remove one of their
  /// own service listings straight from their profile.
  Future<void> _deleteService(ServiceListItem service) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف الخدمة؟'),
        content: Text('سيتم حذف "${service.title}" نهائياً.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _catalog.deleteService(service.id);
      _showMessage('تم حذف الخدمة.');
      _load();
    } on ApiException catch (e) {
      _showMessage(e.message);
    }
  }

  /// «تسجيل الخروج» from the settings menu: nothing is cleared until the
  /// user confirms. Then the stored tokens are removed (AuthService.logout,
  /// the app's one logout path) and the whole stack is replaced by Login.
  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          "تسجيل الخروج",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text("هل أنت متأكد أنك تريد تسجيل الخروج؟"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("إلغاء"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              "تسجيل الخروج",
              style: TextStyle(
                color: logoutColor(dialogContext),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _authService.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: widget.loginBuilder ?? ((_) => const LoginScreen()),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("حسابي"),
        titleSpacing: -2,
        backgroundColor: const Color.fromARGB(0, 77, 75, 75),
        // In RTL the actions sit on the left: the ⚙️ (its menu holds
        // «تسجيل الخروج») is in the top-left corner, with the day/night
        // switch right next to it.
        actions: [
          ProfileHeaderActions(onLogout: _confirmLogout),
          const SizedBox(width: 6),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _load,
              child: const Text("إعادة المحاولة"),
            ),
          ],
        ),
      );
    }

    final user = _user!;
    final profile = user.profile;

    // Only the profile content scrolls. The three action buttons (ساعات
    // الحجز / الإدارة / تعديل الملف الشخصي) sit below it, outside the
    // scroll view, so they stay reachable however many services the user
    // has. Same widgets and spacing as before: the 15 px gap above them and
    // the 20 px screen padding are kept.
    //
    // Flexible with a LOOSE fit (not Expanded): the scroll view is only as
    // tall as its content, up to the space left above the buttons.
    //  * short content -> the buttons follow it directly, 15 px below the
    //    last service, with no empty gap in between;
    //  * long content  -> the scroll view is capped at the available height
    //    and scrolls, while the buttons stay fixed at the bottom.
    return Column(
      children: [
        Flexible(
          fit: FlexFit.loose,
          child: RefreshIndicator(
            onRefresh: _load,
            child: SingleChildScrollView(
              key: const Key('profile-scroll'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                children: [
                  GestureDetector(
                    onTap: profile?.avatarUrl == null
                        ? null
                        : () => Navigator.of(context).push(
                            FullScreenImageViewer.route(
                              imageUrl: ApiConfig.resolveUrl(
                                profile!.avatarUrl!,
                              ),
                            ),
                          ),
                    child: CircleAvatar(
                      radius: 55,
                      backgroundColor: Colors.grey.shade300,
                      backgroundImage: profile?.avatarUrl != null
                          ? sizedNetworkImage(
                              context,
                              ApiConfig.resolveUrl(profile!.avatarUrl!),
                              longestSide: 110,   // radius 55
                            )
                          : null,
                      child: profile?.avatarUrl == null
                          ? const Icon(Icons.person, size: 50)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 15),
                  Text(
                    profile?.fullName ?? user.email,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    user.email,
                    style: const TextStyle(
                      // color: Color.fromARGB(255, 75, 72, 72),
                      color: Colors.grey,
                      fontSize: 16,
                    ),
                  ),
                  if (profile?.phoneNumber != null) ...[
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.phone, size: 18),
                        const SizedBox(width: 5),
                        Text(profile!.phoneNumber!),
                      ],
                    ),
                  ],
                  if (profile?.city != null) ...[
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.location_on, size: 18),
                        const SizedBox(width: 5),
                        Text(profile!.city!),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _statCard("${_services.length}", "الخدمات"),
                      _statCard(user.isProvider ? "نعم" : "لا", "مزوّد خدمة"),
                    ],
                  ),
                  const SizedBox(height: 30),
                  const Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      "نبذة عني",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      (profile?.bio?.isNotEmpty ?? false)
                          ? profile!.bio!
                          : "لا توجد نبذة بعد.",
                    ),
                  ),
                  const SizedBox(height: 15),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "خدماتي",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final added = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder:
                                  widget.addServiceBuilder ??
                                  ((_) => const AddServiceScreen()),
                            ),
                          );
                          if (added == true) _load();
                        },
                        icon: const Icon(Icons.add),
                        label: const Text("إضافة"),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  if (_services.isEmpty)
                    const Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text("لم تنشر أي خدمة بعد."),
                    )
                  else
                    for (final s in _services) _serviceTile(s),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            key: const Key('profile-actions'),
            padding: const EdgeInsets.fromLTRB(20, 15, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    // Booking Hours
                    if (user.isProvider)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    widget.availabilityBuilder?.call(user.id) ??
                                    ProviderAvailabilityScreen(
                                      providerId: user.id,
                                    ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.schedule, size: 17),
                          label: const Text("ساعات الحجز", maxLines: 1),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.blue,
                            side: const BorderSide(color: Colors.blue),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 11,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),

                    if (user.isProvider && user.role == 'admin')
                      const SizedBox(width: 8),

                    // Admin
                    if (user.role == 'admin')
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder:
                                    widget.adminBuilder ??
                                    ((_) => const AdminDashboardScreen()),
                              ),
                            );
                          },
                          icon: const Icon(
                            Icons.admin_panel_settings,
                            size: 17,
                          ),
                          label: const Text("الإدارة", maxLines: 1),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 11,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                ElevatedButton(
                  onPressed: () async {
                    final changed = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            widget.editProfileBuilder?.call(user) ??
                            EditProfileScreen(user: user),
                      ),
                    );
                    if (changed == true) _load();
                  },
                  child: const Text(
                    "تعديل الملف الشخصي",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _statCard(String number, String label) {
    return Column(
      children: [
        Text(
          number,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.grey)),
      ],
    );
  }

  Widget _serviceTile(ServiceListItem service) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.work_outline),
        title: Text(service.title),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'تعديل الخدمة',
              icon: const Icon(
                Icons.edit_outlined,
                color: Color.fromARGB(255, 45, 127, 194),
              ),
              onPressed: () async {
                final updated = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        widget.editServiceBuilder?.call(service.id) ??
                        EditServiceScreen(serviceId: service.id),
                  ),
                );
                if (updated == true) _load();
              },
            ),
            IconButton(
              tooltip: 'إدارة صور الأعمال السابقة',
              icon: const Icon(
                Icons.photo_library_outlined,
                color: Color.fromARGB(255, 145, 135, 49),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        widget.portfolioBuilder?.call(
                          service.id,
                          service.title,
                        ) ??
                        ServicePortfolioScreen(
                          serviceId: service.id,
                          serviceTitle: service.title,
                        ),
                  ),
                );
              },
            ),
            IconButton(
              tooltip: 'حذف الخدمة',
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => _deleteService(service),
            ),
          ],
        ),
      ),
    );
  }
}
