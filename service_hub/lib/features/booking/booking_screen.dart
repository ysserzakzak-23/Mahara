import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../core/utils/status_labels.dart';
import '../auth/data/auth_service.dart';
import 'appointment_details_screen.dart';
import 'data/appointment_models.dart';
import 'data/appointment_service.dart';
import '../../core/utils/error_text.dart';

class BookingScreen extends StatefulWidget {
  const BookingScreen({super.key, this.authService, this.appointmentService});

  /// Optional overrides, mainly so widget tests can inject a fake backend.
  final AuthService? authService;
  final AppointmentService? appointmentService;

  @override
  State<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends State<BookingScreen> {
  late final AuthService _authService = widget.authService ?? AuthService();
  bool _checkingProvider = true;
  bool _isProvider = false;

  @override
  void initState() {
    super.initState();
    _authService
        .currentUser()
        .then((user) {
          if (!mounted) return;
          setState(() {
            _isProvider = user.isProvider;
            _checkingProvider = false;
          });
        })
        .catchError((_) {
          if (!mounted) return;
          setState(() => _checkingProvider = false);
        });
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingProvider) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_isProvider) {
      // Regular customers only ever see their own bookings — no tabs needed.
      return Scaffold(
        appBar: AppBar(
          title: const Text("حجوزاتي"),
          titleSpacing: -1,
          backgroundColor: const Color.fromARGB(0, 77, 75, 75),
        ),
        body: _AppointmentList(
          asProvider: false,
          appointmentService: widget.appointmentService,
        ),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("الحجوزات"),
          titleSpacing: -1,
          backgroundColor: const Color.fromARGB(0, 77, 75, 75),
          bottom: const TabBar(
            tabs: [
              Tab(text: "حجوزاتي"),
              Tab(text: "جدول مواعيدي"),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _AppointmentList(
              asProvider: false,
              appointmentService: widget.appointmentService,
            ),
            _AppointmentList(
              asProvider: true,
              appointmentService: widget.appointmentService,
            ),
          ],
        ),
      ),
    );
  }
}

class _AppointmentList extends StatefulWidget {
  final bool asProvider;
  final AppointmentService? appointmentService;

  const _AppointmentList({required this.asProvider, this.appointmentService});

  @override
  State<_AppointmentList> createState() => _AppointmentListState();
}

class _AppointmentListState extends State<_AppointmentList> {
  /// Rows per request. The backend's own default is 20, its ceiling 100.
  static const _pageSize = 20;

  late final AppointmentService _appointments =
      widget.appointmentService ?? AppointmentService();

  final List<Appointment> _items = [];

  /// The ids already on screen. A booking made or cancelled while the user
  /// is paging shifts every later row, so the same appointment can
  /// legitimately come back on two consecutive pages; this is what keeps
  /// it from being listed twice.
  final Set<int> _shownIds = {};

  bool _loadingFirstPage = true;
  bool _loadingMore = false;

  /// The first page failed: nothing is on screen.
  Object? _error;

  /// A later page failed: what is already loaded stays put, and the list
  /// offers a retry instead of silently stopping.
  Object? _nextPageError;

  bool _hasNext = false;
  int _page = 1;

  /// Incremented by every reload. A reply carrying an older generation is a
  /// stale request - a refresh, or an appointment action, has already
  /// replaced what it was going to show - so it is dropped rather than
  /// overwriting newer rows.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Loads page 1 from scratch, replacing whatever is on screen.
  ///
  /// This is pull-to-refresh, and it is also what every appointment action
  /// does afterwards - accepting, rejecting, cancelling or completing - as
  /// this screen always has.
  Future<void> _refresh() async {
    final generation = ++_generation;
    setState(() {
      _loadingFirstPage = true;
      _loadingMore = false;
      _error = null;
      _nextPageError = null;
    });

    try {
      final result = await _appointments.myAppointments(
        asProvider: widget.asProvider,
        page: 1,
        pageSize: _pageSize,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _items
          ..clear()
          ..addAll(result.items);
        _shownIds
          ..clear()
          ..addAll(result.items.map((a) => a.id));
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
    // Deliberately NOT a new generation: a refresh starting while this is
    // in flight must invalidate it, so it keeps the one it began on.
    final generation = _generation;
    setState(() => _loadingMore = true);

    try {
      final result = await _appointments.myAppointments(
        asProvider: widget.asProvider,
        page: _page + 1,
        pageSize: _pageSize,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        for (final appointment in result.items) {
          if (_shownIds.add(appointment.id)) _items.add(appointment);
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

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Tapping a card opens the full details; if something was changed there
  /// (accepted, rejected, cancelled...) the list is reloaded on the way back.
  Future<void> _openDetails(Appointment a) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AppointmentDetailsScreen(
          appointment: a,
          asProvider: widget.asProvider,
          appointmentService: widget.appointmentService,
        ),
      ),
    );
    if (changed == true && mounted) await _refresh();
  }

  /// Provider action: cancel a booking to free up that exact time slot so
  /// another customer can book the same provider/time — the backend's
  /// conflict check only considers non-cancelled appointments, so this
  /// takes effect immediately.
  Future<void> _cancel(Appointment a) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إلغاء هذا الموعد؟'),
        content: const Text(
          'سيصبح هذا الوقت متاحاً ليحجزه شخص آخر.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('رجوع'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('إلغاء الموعد'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _appointments.cancel(a.id);
      _refresh();
    } on ApiException catch (e) {
      _showMessage(e.message);
    }
  }

  Future<void> _complete(Appointment a) async {
    try {
      await _appointments.complete(a.id);
      _refresh();
    } on ApiException catch (e) {
      _showMessage(e.message);
    }
  }

  /// Provider action: accepts a PENDING booking request, confirming it.
  Future<void> _accept(Appointment a) async {
    try {
      await _appointments.accept(a.id);
      _refresh();
    } on ApiException catch (e) {
      _showMessage(e.message);
    }
  }

  /// Provider action: declines a PENDING booking request, freeing up the
  /// slot for another customer.
  Future<void> _reject(Appointment a) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('رفض طلب الحجز هذا؟'),
        content: const Text(
          'سيتم إشعار العميل، وسيصبح هذا الوقت متاحاً ليحجزه شخص آخر.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('رجوع'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('رفض'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _appointments.reject(a.id);
      _refresh();
    } on ApiException catch (e) {
      _showMessage(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(onRefresh: _refresh, child: _buildBody());
  }

  Widget _buildBody() {
    if (_loadingFirstPage) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      // Scrollable so pull-to-refresh works here too, not only the button.
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Center(child: Text(errorText(_error))),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: _refresh,
              child: const Text("إعادة المحاولة"),
            ),
          ),
        ],
      );
    }

    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Center(
            child: Text(
              widget.asProvider
                  ? "لم يحجزك أحد حتى الآن."
                  : "ليس لديك حجوزات بعد.",
            ),
          ),
        ],
      );
    }

    final hasFooter = _hasNext || _nextPageError != null;
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      itemCount: _items.length + (hasFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 15),
      itemBuilder: (_, i) =>
          i == _items.length ? _buildFooter() : _bookingCard(_items[i]),
    );
  }

  /// The row below the last appointment: either the next page loading, or
  /// the failure that stopped it plus a way to try again.
  Widget _buildFooter() {
    if (_nextPageError != null) {
      return Column(
        children: [
          Text(errorText(_nextPageError), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _retryNextPage,
            child: const Text("إعادة المحاولة"),
          ),
        ],
      );
    }

    // Building this row means the bottom of what is loaded is on screen,
    // which is the signal to fetch the next page. Scheduled after the frame
    // because setState during build is not allowed.
    if (!_loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadNextPage());
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Center(child: CircularProgressIndicator()),
    );
  }

  Widget _bookingCard(Appointment a) {
    final start = a.startTime;
    final dateLabel = start == null
        ? 'بدون موعد محدد'
        : "${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')} "
            "${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}";

    // On the provider's schedule tab, show who booked them; on the
    // customer's own bookings tab, the provider isn't the point — the
    // service is.
    final subtitleExtra = widget.asProvider
        ? " · ${a.customer.displayName}"
        : "";

    final status = a.status.toLowerCase();
    final isPending = status == 'pending';
    final isConfirmed = status == 'confirmed';

    Widget trailing;
    if (widget.asProvider && isPending) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'قبول',
            icon: const Icon(Icons.check_circle_outline, color: Colors.green),
            onPressed: () => _accept(a),
          ),
          IconButton(
            tooltip: 'رفض',
            icon: const Icon(Icons.cancel_outlined, color: Colors.red),
            onPressed: () => _reject(a),
          ),
        ],
      );
    } else if (widget.asProvider && isConfirmed) {
      trailing = PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'cancel') _cancel(a);
          if (value == 'complete') _complete(a);
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'complete', child: Text('تحديد كمكتمل')),
          PopupMenuItem(value: 'cancel', child: Text('إلغاء الموعد')),
        ],
        child: Text(
          appointmentStatusLabel(a.status),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
    } else {
      trailing = Text(
        appointmentStatusLabel(a.status),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: isPending ? Colors.orange.shade800 : null,
        ),
      );
    }

    return Card(
      child: ListTile(
        onTap: () => _openDetails(a),
        leading: const Icon(Icons.calendar_month),
        title: Text(a.serviceTitle),
        subtitle: Text("$dateLabel$subtitleExtra"),
        trailing: trailing,
      ),
    );
  }
}
