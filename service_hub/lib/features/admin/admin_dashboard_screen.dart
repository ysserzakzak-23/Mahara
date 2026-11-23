import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/paged_result.dart';
import '../../core/utils/price_format.dart';
import 'data/admin_models.dart';
import 'data/admin_service.dart';
import '../../core/utils/status_labels.dart';
import '../../core/utils/error_text.dart';

/// Admin-only screen (item: "صفحة الادمن"). Only reachable from the profile
/// screen when the logged-in user's role is "admin" — the backend enforces
/// this independently via `require_admin`, so even a modified client can't
/// actually call these endpoints without an admin account.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key, this.adminService});

  /// Optional override, mainly so widget tests can inject a fake backend.
  final AdminService? adminService;

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen>
    with SingleTickerProviderStateMixin {
  late final AdminService _admin = widget.adminService ?? AdminService();
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("لوحة الإدارة"),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: "الإحصائيات"),
            Tab(text: "المستخدمون"),
            Tab(text: "الخدمات"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _StatsTab(admin: _admin),
          _UsersTab(admin: _admin),
          _ServicesTab(admin: _admin),
        ],
      ),
    );
  }
}

class _StatsTab extends StatefulWidget {
  final AdminService admin;
  const _StatsTab({required this.admin});

  @override
  State<_StatsTab> createState() => _StatsTabState();
}

class _StatsTabState extends State<_StatsTab> {
  late Future<PlatformStats> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.admin.stats();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PlatformStats>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text(errorText(snapshot.error)));
        }
        final s = snapshot.data!;
        final tiles = <(String, String)>[
          ('إجمالي المستخدمين', '${s.totalUsers}'),
          ('مزوّدو الخدمة', '${s.totalProviders}'),
          ('الخدمات النشطة', '${s.activeServices}'),
          ('المواعيد', '${s.totalAppointments}'),
          ('المواعيد المكتملة', '${s.completedAppointments}'),
          ('التقييمات', '${s.totalReviews}'),
          ('متوسط التقييم', s.averagePlatformRating.toStringAsFixed(2)),
        ];
        return GridView.count(
          padding: const EdgeInsets.all(20),
          crossAxisCount: 2,
          childAspectRatio: 1.5,
          mainAxisSpacing: 15,
          crossAxisSpacing: 15,
          children: [
            for (final t in tiles)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        t.$2,
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(t.$1, textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The paging state machine behind both list tabs.
///
/// Opt-in pagination means a page request can be answered in either shape,
/// and [parsePagedResponse] has already reduced both to a [PagedResult]:
/// a legacy bare array arrives as one complete page with `hasNext` false,
/// so this stops after it instead of asking for a page 2 that does not
/// exist. A malformed response is an error, never an empty list.
abstract class _PagedTabState<W extends StatefulWidget, T> extends State<W> {
  /// Rows per request. The backend's own default is 20, its ceiling 100.
  static const _pageSize = 20;

  final List<T> items = [];

  /// The ids already on screen, so a row that shifts across a page boundary
  /// between two requests is not shown twice.
  final Set<int> _shownIds = {};

  bool _loadingFirstPage = true;
  bool _loadingMore = false;
  Object? _error;
  Object? _nextPageError;
  bool _hasNext = false;
  int _page = 1;

  /// Incremented by every reload, so a reply from a request a refresh has
  /// already superseded is dropped rather than overwriting newer rows.
  int _generation = 0;

  // --- what each tab fills in -------------------------------------------

  /// Fetches one page. Called with 1-based page numbers.
  Future<PagedResult<T>> loadPage(int page, int pageSize);

  /// Stable identity of a row, for duplicate prevention.
  int idOf(T item);

  Widget buildRow(BuildContext context, T item);

  // ----------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// Loads page 1 from scratch, dropping whatever is on screen. Used for the
  /// initial load, pull-to-refresh, and after every moderation action.
  Future<void> reload() async {
    final generation = ++_generation;
    setState(() {
      _loadingFirstPage = true;
      _loadingMore = false;
      _error = null;
      _nextPageError = null;
    });

    try {
      final result = await loadPage(1, _pageSize);
      if (!mounted || generation != _generation) return;
      setState(() {
        items
          ..clear()
          ..addAll(result.items);
        _shownIds
          ..clear()
          ..addAll(result.items.map(idOf));
        _page = result.page;
        _hasNext = result.hasNext;
        _loadingFirstPage = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loadingFirstPage = false;
      });
    }
  }

  Future<void> _loadNextPage() async {
    if (_loadingFirstPage || _loadingMore || !_hasNext || _nextPageError != null) {
      return;
    }
    // Keeps the generation it started on: a refresh must invalidate this.
    final generation = _generation;
    setState(() => _loadingMore = true);

    try {
      final result = await loadPage(_page + 1, _pageSize);
      if (!mounted || generation != _generation) return;
      setState(() {
        for (final item in result.items) {
          if (_shownIds.add(idOf(item))) items.add(item);
        }
        _page = result.page;
        _hasNext = result.hasNext;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _nextPageError = error;
        _loadingMore = false;
      });
    }
  }

  void _retryNextPage() {
    setState(() => _nextPageError = null);
    _loadNextPage();
  }

  void showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Runs a moderation action, then reloads — as this screen always has.
  /// A refusal from the backend (403, 422, ...) is shown and nothing
  /// reloads, so the row keeps showing its real state.
  Future<void> runAction(Future<void> Function() action) async {
    try {
      await action();
      await reload();
    } on ApiException catch (e) {
      showMessage(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(onRefresh: reload, child: _buildBody(context));
  }

  Widget _buildBody(BuildContext context) {
    if (_loadingFirstPage) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              children: [
                Text(errorText(_error), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                TextButton(onPressed: reload, child: const Text("إعادة المحاولة")),
              ],
            ),
          ),
        ],
      );
    }

    final hasFooter = _hasNext || _nextPageError != null;
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: items.length + (hasFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) =>
          i == items.length ? _buildFooter() : buildRow(context, items[i]),
    );
  }

  Widget _buildFooter() {
    if (_nextPageError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Text(errorText(_nextPageError), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _retryNextPage,
              child: const Text("إعادة المحاولة"),
            ),
          ],
        ),
      );
    }

    // Reaching this row means the bottom of what is loaded is on screen,
    // which is the signal to fetch the next page. After the frame, because
    // setState during build is not allowed.
    if (!_loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadNextPage());
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _UsersTab extends StatefulWidget {
  final AdminService admin;
  const _UsersTab({required this.admin});

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends _PagedTabState<_UsersTab, AdminUser> {
  @override
  Future<PagedResult<AdminUser>> loadPage(int page, int pageSize) =>
      widget.admin.users(page: page, pageSize: pageSize);

  @override
  int idOf(AdminUser user) => user.id;

  @override
  Widget buildRow(BuildContext context, AdminUser u) {
    return Card(
      child: ListTile(
        title: Text(u.fullName ?? u.email),
        subtitle: Text(
          '${u.email} · ${userRoleLabel(u.role)}${u.isProvider ? ' · مزوّد خدمة' : ''}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: u.role == 'admin'
                  ? 'إزالة صلاحية المشرف'
                  : 'منح صلاحية المشرف',
              icon: Icon(
                Icons.admin_panel_settings,
                color: u.role == 'admin' ? Colors.deepPurple : null,
              ),
              onPressed: () => _toggleRole(u),
            ),
            Switch(
              value: u.isActive,
              onChanged: (_) => _toggleActive(u),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleActive(AdminUser u) =>
      runAction(() => widget.admin.setUserActive(u.id, !u.isActive));

  Future<void> _toggleRole(AdminUser u) {
    final newRole = u.role == 'admin' ? 'user' : 'admin';
    return runAction(() => widget.admin.setUserRole(u.id, newRole));
  }
}

class _ServicesTab extends StatefulWidget {
  final AdminService admin;
  const _ServicesTab({required this.admin});

  @override
  State<_ServicesTab> createState() => _ServicesTabState();
}

class _ServicesTabState extends _PagedTabState<_ServicesTab, AdminServiceListing> {
  @override
  Future<PagedResult<AdminServiceListing>> loadPage(int page, int pageSize) =>
      widget.admin.services(page: page, pageSize: pageSize);

  @override
  int idOf(AdminServiceListing service) => service.id;

  @override
  Widget buildRow(BuildContext context, AdminServiceListing s) {
    final suspended = s.status == 'suspended';
    return Card(
      child: ListTile(
        title: Text(s.title),
        subtitle: Text(
          '${formatPrice(s.price)} · ${serviceStatusLabel(s.status)} · مزوّد #${s.providerId}',
        ),
        trailing: TextButton(
          onPressed: () => _setStatus(s, suspended ? 'active' : 'suspended'),
          child: Text(suspended ? 'إعادة تفعيل' : 'إيقاف'),
        ),
      ),
    );
  }

  Future<void> _setStatus(AdminServiceListing s, String status) =>
      runAction(() => widget.admin.setServiceStatus(s.id, status));
}
