import 'package:flutter/material.dart';
import 'package:service_hub/features/booking/booking_screen.dart';
import 'package:service_hub/features/profile/profile_screen.dart';
import 'package:service_hub/features/search/search_screen.dart';
import 'package:service_hub/features/service/service_details_screen.dart';

import '../../core/config/api_config.dart';
import '../../core/utils/price_format.dart';
import '../auth/data/auth_service.dart';
import '../exchange/exchange_hub_screen.dart';
import '../notifications/data/notification_service.dart';
import '../notifications/notifications_screen.dart';
import '../service/data/catalog_service.dart';
import '../service/data/service_models.dart';
import '../../core/utils/error_text.dart';
import '../../core/utils/image_sizing.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.authService,
    this.catalogService,
    this.notificationService,
    this.notificationsBuilder,
    this.exchangeBuilder,
    this.bookingBuilder,
    this.profileBuilder,
    this.searchBuilder,
    this.detailsBuilder,
  });

  /// Optional overrides, mainly so widget tests can inject a fake backend and
  /// stand-in destination screens. In the real app all are null.
  final AuthService? authService;
  final CatalogService? catalogService;
  final NotificationService? notificationService;
  final WidgetBuilder? notificationsBuilder;
  final WidgetBuilder? exchangeBuilder;
  final WidgetBuilder? bookingBuilder;
  final WidgetBuilder? profileBuilder;
  final WidgetBuilder? searchBuilder;
  final Widget Function(int serviceId)? detailsBuilder;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final AuthService _authService = widget.authService ?? AuthService();
  late final CatalogService _catalog =
      widget.catalogService ?? CatalogService();
  late final NotificationService _notifications =
      widget.notificationService ?? NotificationService();

  int currentIndex = 0;
  final ScrollController _scrollController = ScrollController();
  bool showScrollToTop = false;

  String _greetingName = '';
  int _unreadCount = 0;
  late Future<List<ServiceListItem>> _servicesFuture;

  @override
  void initState() {
    super.initState();
    _servicesFuture = _catalog.services();
    _loadUser();
    _loadUnreadCount();

    _scrollController.addListener(() {
      if (_scrollController.offset > 50 && !showScrollToTop) {
        setState(() => showScrollToTop = true);
      }
      if (_scrollController.offset <= 50 && showScrollToTop) {
        setState(() => showScrollToTop = false);
      }
    });
  }

  Future<void> _loadUser() async {
    try {
      final user = await _authService.currentUser();
      if (!mounted) return;
      setState(() => _greetingName = user.profile?.fullName ?? '');
    } catch (_) {
      // Non-fatal: greeting just stays generic.
    }
  }

  Future<void> _loadUnreadCount() async {
    try {
      final count = await _notifications.unreadCount();
      if (!mounted) return;
      setState(() => _unreadCount = count);
    } catch (_) {
      // Non-fatal: the bell just won't show a badge this session.
    }
  }

  Future<void> _openNotifications() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            widget.notificationsBuilder ?? ((_) => const NotificationsScreen()),
      ),
    );
    _loadUnreadCount();
  }

  Future<void> _refresh() async {
    final future = _catalog.services();
    setState(() {
      _servicesFuture = future;
    });
    await future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: showScrollToTop ? 1 : 0,
        child: showScrollToTop
            ? FloatingActionButton(
                elevation: 6,
                onPressed: () {
                  _scrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeInOut,
                  );
                },
                child: const Icon(Icons.keyboard_arrow_up),
              )
            : null,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        // backgroundColor: Colors.white,
        // indicatorColor: Colors.grey.shade300,
        onDestinationSelected: (index) {
          if (index == 2) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder:
                    widget.exchangeBuilder ??
                    ((_) => const ExchangeHubScreen()),
              ),
            );
          } else if (index == 3) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder:
                    widget.bookingBuilder ?? ((_) => const BookingScreen()),
              ),
            );
          } else if (index == 4) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder:
                    widget.profileBuilder ?? ((_) => const ProfileScreen()),
              ),
              // Services are added from the profile now, so refresh the
              // list here when coming back from it.
            ).then((_) => _refresh());
          } else if (index == 1) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: widget.searchBuilder ?? ((_) => const SearchScreen()),
              ),
            );
          }
          setState(() => currentIndex = index);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: "الرئيسية"),
          NavigationDestination(icon: Icon(Icons.search), label: "بحث"),
          NavigationDestination(
            icon: Icon(Icons.swap_horiz),
            label: "المقايضة",
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month),
            label: "الحجوزات",
          ),
          NavigationDestination(icon: Icon(Icons.person), label: "حسابي"),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _refresh,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: SingleChildScrollView(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 20),
                      Text(
                        _greetingName.isEmpty
                            ? "مرحباً 👋"
                            : "مرحباً، $_greetingName 👋",
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 25),
                      Hero(
                        tag: "searchBar",
                        child: Material(
                          color: Colors.transparent,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black12,
                                  blurRadius: 8,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  PageRouteBuilder(
                                    transitionDuration: const Duration(
                                      milliseconds: 450,
                                    ),
                                    pageBuilder: (_, animation, secondary) {
                                      return FadeTransition(
                                        opacity: animation,
                                        child:
                                            widget.searchBuilder?.call(
                                              context,
                                            ) ??
                                            const SearchScreen(),
                                      );
                                    },
                                  ),
                                );
                              },
                              child: const AbsorbPointer(
                                child: TextField(
                                  decoration: InputDecoration(
                                    hintText: "ابحث عن خدمة",
                                    prefixIcon: Icon(Icons.search),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 30),
                      const Text(
                        "جميع الخدمات",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 15),
                      FutureBuilder<List<ServiceListItem>>(
                        future: _servicesFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const Padding(
                              padding: EdgeInsets.all(40),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          if (snapshot.hasError) {
                            return _ErrorBox(
                              message: errorText(snapshot.error),
                              onRetry: _refresh,
                            );
                          }
                          final services = snapshot.data ?? [];
                          if (services.isEmpty) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 40),
                              child: Center(child: Text("لا توجد خدمات حالياً.")),
                            );
                          }
                          return Column(
                            children: [
                              for (final s in services) ...[
                                GestureDetector(
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            widget.detailsBuilder?.call(s.id) ??
                                            ServiceDetailsScreen(
                                              serviceId: s.id,
                                            ),
                                      ),
                                    );
                                  },
                                  child: serviceCard(s),
                                ),
                                const SizedBox(height: 15),
                              ],
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // The bell takes the corner the old ⋮ menu used (its theme and
            // logout items now live in the settings menu on «حسابي»).
            PositionedDirectional(
              top: 10,
              end: 15,
              child: IconButton(
                key: const Key('home-notifications'),
                tooltip: 'الإشعارات',
                onPressed: _openNotifications,
                icon: Badge(
                  isLabelVisible: _unreadCount > 0,
                  label: Text('$_unreadCount'),
                  child: const Icon(Icons.notifications_outlined),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget serviceCard(ServiceListItem service) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        // color: Colors.white,
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black12)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 130,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(15),
              image: service.coverImageUrl != null
                  ? DecorationImage(
                      image: sizedNetworkImage(
                        context,
                        ApiConfig.resolveUrl(service.coverImageUrl!),
                        longestSide: MediaQuery.sizeOf(context).width,
                      ),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 15),
          Text(
            service.title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text("بواسطة ${service.provider.displayName}"),
          const SizedBox(height: 8),
          Text(formatPrice(service.price)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ErrorBox({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: Column(
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text("إعادة المحاولة")),
        ],
      ),
    );
  }
}
