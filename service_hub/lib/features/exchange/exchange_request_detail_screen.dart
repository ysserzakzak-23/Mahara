import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../core/config/api_config.dart';
import '../../core/storage/token_store.dart';
import '../booking/create_booking_screen.dart';
import '../service/data/catalog_service.dart';
import '../service/data/service_models.dart';
import 'data/exchange_models.dart';
import 'data/exchange_service.dart';
import '../profile/provider_profile_screen.dart';
import '../../core/utils/status_labels.dart';
import '../../core/utils/error_text.dart';
import '../../core/utils/image_sizing.dart';

/// Shows one ExchangeRequest.
///  - Owner view: direct matches + proposals received on it, and a way to
///    close the request.
///  - Everyone else: a "Send Proposal" action (if the request is still
///    open), or — once one of their own proposals on it is accepted — a
///    "Book Appointment" action for the exchanged service.
class ExchangeRequestDetailScreen extends StatefulWidget {
  final ExchangeRequestModel request;

  /// Optional overrides, mainly so widget tests can inject a fake backend.
  final TokenStore? tokenStore;
  final ExchangeService? exchangeService;
  final CatalogService? catalogService;
  final Widget Function(int serviceId, String serviceTitle, int providerId)?
  bookingBuilder;
  final Widget Function(int providerId)? profileBuilder;

  const ExchangeRequestDetailScreen({
    super.key,
    required this.request,
    this.tokenStore,
    this.exchangeService,
    this.catalogService,
    this.bookingBuilder,
    this.profileBuilder,
  });

  @override
  State<ExchangeRequestDetailScreen> createState() =>
      _ExchangeRequestDetailScreenState();
}

class _ExchangeRequestDetailScreenState
    extends State<ExchangeRequestDetailScreen> {
  late final TokenStore _tokenStore = widget.tokenStore ?? TokenStore();
  late final ExchangeService _exchange =
      widget.exchangeService ?? ExchangeService();
  late ExchangeRequestModel _request;
  int? _myUserId;
  bool _loading = true;
  String? _error;

  List<DirectMatch> _matches = [];
  List<ExchangeProposalModel> _proposalsOnThisRequest = [];
  // Only populated when I'm NOT the request's owner: my own proposal(s)
  // sent to this specific request, so I can tell if one was accepted.
  List<ExchangeProposalModel> _myProposalsOnThisRequest = [];

  @override
  void initState() {
    super.initState();
    _request = widget.request;
    _load();
  }

  bool get _isMine => _myUserId != null && _myUserId == _request.user.id;

  /// My own proposal on this request that the owner accepted, if any —
  /// that's what unlocks my "Book Appointment" button.
  ExchangeProposalModel? get _myAcceptedProposal {
    for (final p in _myProposalsOnThisRequest) {
      if (p.status == 'accepted') return p;
    }
    return null;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Who I am, for the owner check below. Read from the access token
      // on the device instead of fetching the whole profile from
      // /users/me, which this used for the id alone. Null — a missing or
      // unreadable token — leaves _myUserId null, so _isMine stays false
      // and the owner sections are never shown to an unknown user; the
      // request that follows then fails as it always did, and the existing
      // error state reports it.
      _myUserId = await _tokenStore.currentUserId;

      // One request-scoped call either way: the backend returns every
      // proposal on the request to its owner and only my own to anyone
      // else, so there is nothing left to filter here. This used to read
      // every proposal I could see anywhere and throw most of them away.
      if (_myUserId == _request.user.id) {
        final matchesFuture = _exchange.matchesForRequest(_request.id);
        final proposalsFuture = _exchange.proposalsForRequest(_request.id);
        _matches = await matchesFuture;
        _proposalsOnThisRequest = await proposalsFuture;
      } else {
        _myProposalsOnThisRequest =
            await _exchange.proposalsForRequest(_request.id);
      }

      if (!mounted) return;
      setState(() => _loading = false);
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

  Future<void> _closeRequest() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('سحب طلب التبادل؟'),
        content: const Text('لن يظهر بعد ذلك للمستخدمين الآخرين.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('رجوع'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('سحب الطلب',style: TextStyle(
              color: Colors.red,
            ),),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _exchange.closeRequest(_request.id);
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      _showMessage(e.message);
    }
  }

  Future<void> _respondToProposal(ExchangeProposalModel p, bool accept) async {
    try {
      // The answer carries the request as it now stands — accepting moves it
      // to «محجوز» — so the screen can show the new state without a
      // second round trip. Nothing is assumed before the backend confirms:
      // on failure we fall into the catch below and leave _request alone.
      final answered = accept
          ? await _exchange.acceptProposal(p.id)
          : await _exchange.rejectProposal(p.id);
      if (!mounted) return;
      setState(() => _request = answered.request);
      _load();
    } on ApiException catch (e) {
      _showMessage(e.message);
    }
  }

  Future<void> _sendProposal() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SendProposalSheet(
        requestId: _request.id,
        tokenStore: widget.tokenStore,
        catalogService: widget.catalogService,
        exchangeService: widget.exchangeService,
      ),
    );
    if (result == true) {
      if (!mounted) return;
      _showMessage('تم إرسال الاقتراح!');
      Navigator.pop(context, true);
    }
  }

  /// Opens the normal (free, no-payment) booking flow for the service the
  /// other side is offering — used once a proposal on this request has
  /// been accepted, so both sides can each book a time with the other
  /// instead of having to go find each other's service listing manually.
  void _bookAppointment({
    required int serviceId,
    required String serviceTitle,
    required int providerId,
    bool isRemote = false,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            widget.bookingBuilder?.call(serviceId, serviceTitle, providerId) ??
            CreateBookingScreen(
              serviceId: serviceId,
              serviceTitle: serviceTitle,
              providerId: providerId,
              isRemote: isRemote,
            ),
      ),
    );
  }

  Widget _profile(int providerId) =>
      widget.profileBuilder?.call(providerId) ??
      ProviderProfileScreen(providerId: providerId);

  @override
  Widget build(BuildContext context) {
    final r = _request;
    return Scaffold(
      appBar: AppBar(
        title: const Text("تفاصيل طلب التبادل"),
        backgroundColor: const Color.fromARGB(0, 77, 75, 75),
        actions: [
          if (_isMine && r.isOpen)
            IconButton(
              tooltip: 'سحب الطلب',
              icon: const Icon(Icons.close),
              onPressed: _closeRequest,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _requestSummaryCard(r),
              const SizedBox(height: 24),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_error != null)
                Text(_error!)
              else if (_isMine) ...[
                const Text(
                  "التطابقات المباشرة",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                if (_matches.isEmpty)
                  const Text("لا توجد تطابقات مباشرة بعد.")
                else
                  for (final m in _matches) _matchCard(m),
                const SizedBox(height: 24),
                const Text(
                  "الاقتراحات المستلمة",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                if (_proposalsOnThisRequest.isEmpty)
                  const Text("لم يصل أي اقتراح بعد.")
                else
                  for (final p in _proposalsOnThisRequest)
                    _proposalCard(p, showActions: p.isPending && r.isOpen),
              ] else if (_myAcceptedProposal != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.green.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          "تم قبول اقتراحك! احجز موعدك مع الطرف الآخر.",
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  onPressed: () => _bookAppointment(
                    serviceId: r.offeredService.id,
                    serviceTitle: r.offeredService.title,
                    providerId: r.user.id,
                    isRemote: r.offeredService.isRemote,
                  ),
                  icon: const Icon(Icons.calendar_month, color: Colors.white),
                  label: Text(
                    "احجز موعداً مع ${r.user.displayName}",
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ] else if (_myProposalsOnThisRequest.any((p) => p.isPending))
                const Text("اقتراحك بانتظار موافقة صاحب الطلب.")
              else if (_myProposalsOnThisRequest.isNotEmpty &&
                  _myProposalsOnThisRequest.every(
                    (p) => p.status == 'rejected',
                  ))
                const Text("تم رفض اقتراحك على هذا الطلب.")
              else if (r.isOpen)
                ElevatedButton.icon(
                  onPressed: _sendProposal,
                  icon: const Icon(Icons.swap_horiz, color: Colors.white),
                  label: const Text(
                    "أرسل اقتراح",
                    style: TextStyle(color: Colors.white),
                  ),
                )
              else
                const Text("هذا الطلب غير مفتوح حالياً."),
            ],
          ),
        ),
      ),
    );
  }

  Widget _requestSummaryCard(ExchangeRequestModel r) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          _profile(r.user.id),
                    ),
                  ),
                  child: CircleAvatar(
                    backgroundColor: Colors.grey.shade300,
                    backgroundImage: r.user.avatarUrl != null
                        ? sizedNetworkImage(
                            context,
                            ApiConfig.resolveUrl(r.user.avatarUrl!),
                            longestSide: 40,    // default CircleAvatar
                          )
                        : null,
                    child: r.user.avatarUrl == null
                        ? const Icon(Icons.person)
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            _profile(r.user.id),
                      ),
                    ),
                    child: Text(
                      r.user.displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
                _statusChip(r.status, exchangeRequestStatusLabel(r.status)),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.upload, size: 18, color: Colors.green),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    r.offeredService.title == r.offeredCategory.name
                        ? "يعرض: ${r.offeredService.title}"
                        : "يعرض: ${r.offeredService.title} (${r.offeredCategory.name})",
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.download, size: 18, color: Colors.orange),
                const SizedBox(width: 6),
                Text("يريد: ${r.wantedCategoryLabel}"),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _matchCard(DirectMatch m) {
    final other = m.otherRequest;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.compare_arrows, color: Colors.blue),
        title: Text(other.offeredService.title),
        subtitle: Text(
          "${other.user.displayName} · يريد ${other.wantedCategoryLabel}",
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ExchangeRequestDetailScreen(
                request: other,
                tokenStore: widget.tokenStore,
                exchangeService: widget.exchangeService,
                catalogService: widget.catalogService,
                bookingBuilder: widget.bookingBuilder,
                profileBuilder: widget.profileBuilder,
              ),
            ),
          ).then((_) => _load());
        },
      ),
    );
  }

  Widget _proposalCard(ExchangeProposalModel p, {required bool showActions}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => _profile(p.proposer.id),
                          ),
                        ),
                        child: Text(
                          p.proposer.displayName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            //  color: Colors.black,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                      Text(
                        " يقترح: ${p.proposedService.title}",
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                _statusChip(p.status, exchangeProposalStatusLabel(p.status)),
              ],
            ),
            if (p.message != null && p.message!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(p.message!, style: const TextStyle(color: Colors.grey)),
            ],
            if (showActions) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => _respondToProposal(p, true),
                    icon: const Icon(Icons.check, color: Colors.green),
                    label: const Text("قبول"),
                  ),
                  TextButton.icon(
                    onPressed: () => _respondToProposal(p, false),
                    icon: const Icon(Icons.close, color: Colors.red),
                    label: const Text("رفض"),
                  ),
                ],
              ),
            ],
            if (p.status == 'accepted') ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _bookAppointment(
                  serviceId: p.proposedService.id,
                  serviceTitle: p.proposedService.title,
                  providerId: p.proposer.id,
                  isRemote: p.proposedService.isRemote,
                ),
                icon: const Icon(Icons.calendar_month),
                label: Text("احجز موعداً مع ${p.proposer.displayName}"),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// [status] is the internal value (it picks the colour); [label] is
  /// what the user reads.
  Widget _statusChip(String status, String label) {
    Color color;
    switch (status) {
      case 'open':
      case 'pending':
        color = Colors.orange;
        break;
      case 'matched':
      case 'accepted':
        color = Colors.green;
        break;
      default:
        color = Colors.grey;
    }
    return Chip(
      label: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      backgroundColor: color,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Bottom sheet: pick one of my own services + optional message, then
/// POST /exchange-requests/{id}/proposals.
class _SendProposalSheet extends StatefulWidget {
  final int requestId;
  final TokenStore? tokenStore;
  final CatalogService? catalogService;
  final ExchangeService? exchangeService;

  const _SendProposalSheet({
    required this.requestId,
    this.tokenStore,
    this.catalogService,
    this.exchangeService,
  });

  @override
  State<_SendProposalSheet> createState() => _SendProposalSheetState();
}

class _SendProposalSheetState extends State<_SendProposalSheet> {
  late final TokenStore _tokenStore = widget.tokenStore ?? TokenStore();
  late final CatalogService _catalog =
      widget.catalogService ?? CatalogService();
  late final ExchangeService _exchange =
      widget.exchangeService ?? ExchangeService();
  final _messageController = TextEditingController();

  late Future<List<ServiceListItem>> _myServicesFuture;
  int? _proposedServiceId;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _myServicesFuture = _loadMyServices();
  }

  Future<List<ServiceListItem>> _loadMyServices() async {
    // My id, from the token on the device: only my own services may be
    // proposed, and this used to fetch the whole profile to learn which
    // provider that is. A null id is surfaced by the FutureBuilder's
    // existing error state rather than listing nothing, which would read
    // as "you have no services".
    final myId = await _tokenStore.currentUserId;
    if (myId == null) {
      throw StateError('no readable user id in the stored access token');
    }
    return _catalog.servicesByProvider(myId);
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _submit() async {
    if (_proposedServiceId == null) {
      _showMessage('اختر إحدى خدماتك التي تريد عرضها.');
      return;
    }
    setState(() => _submitting = true);
    try {
      await _exchange.createProposal(
        requestId: widget.requestId,
        proposedServiceId: _proposedServiceId!,
        message: _messageController.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "أرسل اقتراح",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 16),
            FutureBuilder<List<ServiceListItem>>(
              future: _myServicesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const LinearProgressIndicator();
                }
                if (snapshot.hasError) {
                  return Text(errorText(snapshot.error));
                }
                final services = snapshot.data ?? [];
                if (services.isEmpty) {
                  return const Text(
                    "يجب أن تملك خدمة منشورة قبل إرسال اقتراح.",
                  );
                }
                return DropdownButtonFormField<int>(
                  initialValue: _proposedServiceId,
                  isExpanded: true,
                  items: [
                    for (final s in services)
                      DropdownMenuItem(value: s.id, child: Text(s.title)),
                  ],
                  onChanged: (value) =>
                      setState(() => _proposedServiceId = value),
                  decoration: const InputDecoration(hintText: "خدمتك"),
                );
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _messageController,
              maxLines: 3,
              decoration: const InputDecoration(hintText: "رسالة (اختياري)"),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text("إرسال", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}
