import 'package:flutter/material.dart';

import 'data/notification_models.dart';
import 'data/notification_service.dart';
import '../../core/utils/error_text.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key, this.service});

  /// Optional override, mainly so widget tests can inject a fake backend.
  final NotificationService? service;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  /// Rows per request. The backend's own default is 20 and its ceiling 100.
  static const _pageSize = 20;

  late final NotificationService _service =
      widget.service ?? NotificationService();

  final List<AppNotification> _items = [];

  /// The ids already on screen. A notification arriving while the user pages
  /// shifts every later row down by one, so the same row can legitimately
  /// come back on two consecutive pages; this is what keeps it from being
  /// shown twice.
  final Set<int> _shownIds = {};

  bool _loadingFirstPage = true;
  bool _loadingMore = false;

  /// The first page failed: nothing is on screen.
  Object? _error;

  /// A later page failed: what is already on screen stays, and the list
  /// offers a retry rather than silently stopping.
  Object? _nextPageError;

  bool _hasNext = false;
  int _page = 1;

  /// Incremented by every reload. A reply carrying an older generation is a
  /// stale request — a refresh has already replaced what it was going to
  /// show — so it is dropped instead of overwriting newer rows.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _loadFirstPage();
  }

  /// Loads page 1 from scratch, replacing whatever is on screen. Used for
  /// the initial load, pull-to-refresh, and after a mark-read call.
  Future<void> _loadFirstPage() async {
    final generation = ++_generation;
    setState(() {
      _loadingFirstPage = true;
      _loadingMore = false;
      _error = null;
      _nextPageError = null;
    });

    try {
      final result = await _service.list(page: 1, pageSize: _pageSize);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items
          ..clear()
          ..addAll(result.items);
        _shownIds
          ..clear()
          ..addAll(result.items.map((n) => n.id));
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
    // Deliberately NOT a new generation: a refresh that starts while this is
    // in flight must invalidate it, so this keeps the generation it began on.
    final generation = _generation;
    setState(() => _loadingMore = true);

    try {
      final result = await _service.list(page: _page + 1, pageSize: _pageSize);
      if (!mounted || generation != _generation) return;
      setState(() {
        for (final notification in result.items) {
          if (_shownIds.add(notification.id)) _items.add(notification);
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

  Future<void> _markAllRead() async {
    await _service.markAllRead();
    await _loadFirstPage();
  }

  Future<void> _tapNotification(AppNotification n) async {
    if (!n.isRead) {
      await _service.markRead(n.id);
      await _loadFirstPage();
    }
  }

  IconData _iconFor(String type) {
    if (type.startsWith('appointment')) return Icons.event_note;
    if (type.startsWith('exchange')) return Icons.swap_horiz;
    if (type == 'barter_match') return Icons.handshake_outlined;
    if (type == 'new_review') return Icons.star_border;
    return Icons.notifications_none;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("الإشعارات"),
        actions: [
          TextButton(
            onPressed: _markAllRead,
            child: const Text("تحديد الكل كمقروء"),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadFirstPage,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loadingFirstPage) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      // Scrollable so pull-to-refresh works here too, not just the button.
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              children: [
                Text(errorText(_error), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _loadFirstPage,
                  child: const Text("إعادة المحاولة"),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: Text("لا توجد إشعارات بعد.")),
          ),
        ],
      );
    }

    final hasFooter = _hasNext || _nextPageError != null;
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: _items.length + (hasFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (_, i) {
        if (i == _items.length) return _buildFooter();

        final n = _items[i];
        return Card(
          color: n.isRead ? null : const Color.fromARGB(255, 144, 146, 147),
          child: ListTile(
            leading: Icon(
              _iconFor(n.type),
              color: n.isRead ? null : Colors.black,
            ),
            title: Text(
              n.title,
              style: TextStyle(
                color: n.isRead ? null : Colors.black,
                fontWeight: n.isRead ? FontWeight.normal : FontWeight.bold,
              ),
            ),
            subtitle: Text(
              n.message,
              style: TextStyle(color: n.isRead ? null : Colors.black),
            ),
            onTap: () => _tapNotification(n),
          ),
        );
      },
    );
  }

  /// The row below the last notification: either the next page loading, or
  /// the failure that stopped it plus a way to try again.
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

    // Building this row means the user has reached the bottom of what is
    // loaded, which is the signal to fetch the next page. Scheduled after
    // the frame because setState during build is not allowed.
    if (!_loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadNextPage());
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(child: CircularProgressIndicator()),
    );
  }
}
