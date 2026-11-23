import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/paged_result.dart';
import '../../core/storage/token_store.dart';
import 'create_exchange_request_screen.dart';
import 'data/exchange_models.dart';
import 'data/exchange_service.dart';
import 'exchange_request_detail_screen.dart';
import '../../core/utils/status_labels.dart';
import '../../core/utils/error_text.dart';

/// Entry point for the whole Exchange Request/Proposal flow
/// ("اطلب/اقترح/وافق"). Reached from the «المقايضة» item of the bottom
/// navigation bar.
///
/// Tabs: تصفح (all open requests, with smart search) · طلباتي ·
/// العروض الواردة · العروض المرسلة · اهتماماتي (requests looking for a
/// service I offer, by offered-service rating, with smart search).
class ExchangeHubScreen extends StatefulWidget {
  const ExchangeHubScreen({
    super.key,
    this.tokenStore,
    this.exchangeService,
    this.createRequestBuilder,
    this.detailBuilder,
  });

  /// Optional overrides, mainly so widget tests can inject a fake backend.
  final TokenStore? tokenStore;
  final ExchangeService? exchangeService;
  final WidgetBuilder? createRequestBuilder;
  final Widget Function(ExchangeRequestModel request)? detailBuilder;

  @override
  State<ExchangeHubScreen> createState() => _ExchangeHubScreenState();
}

class _ExchangeHubScreenState extends State<ExchangeHubScreen> {
  final GlobalKey<_RequestListState> _browseKey = GlobalKey();
  final GlobalKey<_RequestListState> _mineKey = GlobalKey();
  final GlobalKey<_ProposalListState> _receivedKey = GlobalKey();
  final GlobalKey<_ProposalListState> _sentKey = GlobalKey();
  final GlobalKey<_RequestListState> _interestsKey = GlobalKey();

  Future<void> _openCreateRequest() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder:
            widget.createRequestBuilder ??
            ((_) => const CreateExchangeRequestScreen()),
      ),
    );
    if (created == true) {
      _browseKey.currentState?.refresh();
      _mineKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("المقايضة"),
          titleSpacing: -2,
          backgroundColor: const Color.fromARGB(0, 77, 75, 75),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: "تصفح"),
              Tab(text: "طلباتي"),
              Tab(text: "العروض الواردة"),
              Tab(text: "العروض المرسلة"),
              Tab(text: "اهتماماتي"),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _openCreateRequest,
          child: const Icon(Icons.add),
        ),
        body: TabBarView(
          children: [
            _RequestList(
              key: _browseKey,
              mode: _RequestListMode.browse,
              tokenStore: widget.tokenStore,
              exchangeService: widget.exchangeService,
              detailBuilder: widget.detailBuilder,
            ),
            _RequestList(
              key: _mineKey,
              mode: _RequestListMode.mine,
              tokenStore: widget.tokenStore,
              exchangeService: widget.exchangeService,
              detailBuilder: widget.detailBuilder,
            ),
            _ProposalList(
              key: _receivedKey,
              sent: false,
              exchangeService: widget.exchangeService,
              detailBuilder: widget.detailBuilder,
            ),
            _ProposalList(
              key: _sentKey,
              sent: true,
              exchangeService: widget.exchangeService,
              detailBuilder: widget.detailBuilder,
            ),
            _RequestList(
              key: _interestsKey,
              mode: _RequestListMode.interests,
              tokenStore: widget.tokenStore,
              exchangeService: widget.exchangeService,
              detailBuilder: widget.detailBuilder,
            ),
          ],
        ),
      ),
    );
  }
}

enum _RequestListMode { browse, mine, interests }

/// One list of exchange requests.
///
/// * [_RequestListMode.browse] — every open request except mine; the search
///   field on top switches to the backend's smart Arabic search.
/// * [_RequestListMode.interests] — «اهتماماتي»: open requests from people
///   looking for a service I offer, sorted by the offered service's rating;
///   the search field narrows within that same set (never beyond it).
/// * [_RequestListMode.mine] — my own requests (no search field).
///
/// Searching follows the main search page: it waits until the user pauses
/// typing, and a slow answer to an old search never overwrites a newer one.
class _RequestList extends StatefulWidget {
  final _RequestListMode mode;
  final TokenStore? tokenStore;
  final ExchangeService? exchangeService;
  final Widget Function(ExchangeRequestModel request)? detailBuilder;

  const _RequestList({
    super.key,
    required this.mode,
    this.tokenStore,
    this.exchangeService,
    this.detailBuilder,
  });

  @override
  State<_RequestList> createState() => _RequestListState();
}

class _RequestListState extends State<_RequestList> {
  late final TokenStore _tokenStore = widget.tokenStore ?? TokenStore();
  late final ExchangeService _exchange =
      widget.exchangeService ?? ExchangeService();
  final _queryController = TextEditingController();

  static const _debounceDelay = Duration(milliseconds: 450);

  /// Rows per request. The backend's own default is 20, its ceiling 100.
  static const _pageSize = 20;

  final List<ExchangeRequestModel> _requests = [];

  /// The ids on screen, so a request that shifts across a page boundary
  /// between two calls is not listed twice.
  final Set<int> _shownIds = {};

  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  /// A later page failed: what is loaded stays, with a retry at the end.
  String? _nextPageError;

  bool _hasNext = false;
  int _page = 1;

  // The text of the last search that was sent, and a counter so a slow
  // answer to an old search — or to a page of it — can never overwrite a
  // newer one.
  String _searchedQuery = '';
  int _requestId = 0;
  Timer? _debounce;

  bool get _searchable => widget.mode != _RequestListMode.mine;

  @override
  void initState() {
    super.initState();
    if (_searchable) _queryController.addListener(_onQueryChanged);
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    _debounce?.cancel();
    if (_queryController.text.trim() == _searchedQuery) return;
    _debounce = Timer(_debounceDelay, _reload);
  }

  /// One page of this tab's list, for [query].
  ///
  /// The page number and the query travel together, so page 2 is always
  /// page 2 *of the same search* — the backend ranks the whole candidate
  /// set and hands back the slice, so the ordering is the server's and the
  /// pages fit together.
  Future<PagedResult<ExchangeRequestModel>> _fetch(String query, int page) async {
    switch (widget.mode) {
      case _RequestListMode.mine:
        return _exchange.listMyRequests(page: page, pageSize: _pageSize);
      case _RequestListMode.interests:
        // The backend already leaves out my own requests and sorts by the
        // offered service's rating (or by relevance when searching).
        return _exchange.listInterests(
          query: query,
          page: page,
          pageSize: _pageSize,
        );
      case _RequestListMode.browse:
        // Open requests (or the smart-search results), minus the current
        // user's own: those already show up under "طلباتي" and
        // self-proposing is blocked anyway. The backend leaves them out
        // now, so nothing is filtered here.
        if (query.isEmpty) {
          // The public list is fetched without a token, so it has to be
          // told whose requests to drop. The id comes out of the access
          // token already on the device, which costs no round trip — null
          // (no token, or one that cannot be read) simply excludes
          // nothing, which is the right list for a visitor anyway.
          final myId = await _tokenStore.currentUserId;
          return _exchange.listOpenRequests(
            excludeUserId: myId,
            page: page,
            pageSize: _pageSize,
          );
        }
        // Search is sent the token and excludes the caller's own itself,
        // so it needs no extra round trip to learn who that is.
        return _exchange.searchRequests(query, page: page, pageSize: _pageSize);
    }
  }

  /// Loads page 1 for the current search text, dropping whatever is on
  /// screen. Every change of query, every pull-to-refresh and every
  /// mutation comes through here, so pagination always restarts at 1 and
  /// the previous query's rows are never appended to the new one's.
  Future<void> _reload() async {
    _debounce?.cancel();
    final query = _searchable ? _queryController.text.trim() : '';
    _searchedQuery = query;
    // A new generation: any page still in flight for the previous query
    // belongs to it and will be dropped when it answers.
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _nextPageError = null;
    });
    try {
      final result = await _fetch(query, 1);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _requests
          ..clear()
          ..addAll(result.items);
        _shownIds
          ..clear()
          ..addAll(result.items.map((r) => r.id));
        _page = result.page;
        _hasNext = result.hasNext;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadNextPage() async {
    if (_loading || _loadingMore || !_hasNext || _nextPageError != null) return;
    // Deliberately NOT a new generation: a reload, or a new search, must
    // invalidate this, so it keeps the one it started on — and with it the
    // query it belongs to.
    final requestId = _requestId;
    final query = _searchedQuery;
    setState(() => _loadingMore = true);

    try {
      final result = await _fetch(query, _page + 1);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        for (final request in result.items) {
          if (_shownIds.add(request.id)) _requests.add(request);
        }
        _page = result.page;
        _hasNext = result.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _nextPageError = errorText(e);
        _loadingMore = false;
      });
    }
  }

  void _retryNextPage() {
    setState(() => _nextPageError = null);
    _loadNextPage();
  }

  /// Reloads with the current search text (after creating a request or
  /// coming back from a request's details).
  void refresh() => _reload();

  @override
  Widget build(BuildContext context) {
    final list = RefreshIndicator(onRefresh: _reload, child: _buildBody());
    if (!_searchable) return list;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: TextField(
            controller: _queryController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) {
              if (_queryController.text.trim() != _searchedQuery) _reload();
            },
            decoration: InputDecoration(
              hintText: widget.mode == _RequestListMode.interests
                  ? "ابحث ضمن اهتماماتي.."
                  : "ابحث في طلبات المقايضة..",
              prefixIcon: const Icon(Icons.search),
            ),
          ),
        ),
        Expanded(child: list),
      ],
    );
  }

  /// A scrollable message, so pull-to-refresh still works on it.
  Widget _message(List<Widget> children) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [const SizedBox(height: 120), ...children],
      );

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(semanticsLabel: "جارٍ التحميل..."),
      );
    }
    if (_error != null) {
      return _message([
        Center(child: Text(_error!, textAlign: TextAlign.center)),
        if (_searchable) ...[
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton(
              onPressed: _reload,
              child: const Text("إعادة المحاولة"),
            ),
          ),
        ],
      ]);
    }
    if (_requests.isEmpty) {
      return _message([
        Center(child: Text(_emptyText(), textAlign: TextAlign.center)),
      ]);
    }
    final hasFooter = _hasNext || _nextPageError != null;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 90),
      itemCount: _requests.length + (hasFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, i) =>
          i == _requests.length ? _footer() : _requestCard(_requests[i]),
    );
  }

  /// The row under the last request: the next page arriving, or the
  /// failure that stopped it with a way to try the same page again.
  Widget _footer() {
    if (_nextPageError != null) {
      return Column(
        children: [
          Text(_nextPageError!, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _retryNextPage,
            child: const Text("إعادة المحاولة"),
          ),
        ],
      );
    }
    // Building this row means the bottom of what is loaded is on screen,
    // which is the signal to fetch the next page. After the frame, because
    // setState during build is not allowed.
    if (!_loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadNextPage());
    }
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: CircularProgressIndicator(semanticsLabel: "جارٍ التحميل..."),
      ),
    );
  }

  String _emptyText() {
    if (_searchedQuery.isNotEmpty) {
      return "لم نجد طلبات مطابقة لبحثك، جرّب كلمات أخرى.";
    }
    switch (widget.mode) {
      case _RequestListMode.mine:
        return "لم تفتح أي طلب تبادل بعد.";
      case _RequestListMode.interests:
        return "لا توجد حالياً طلبات تبحث عن خدمة تقدّمها.\n"
            "تظهر هنا طلبات من يبحثون عن الخدمات المنشورة في حسابك.";
      case _RequestListMode.browse:
        return "لا توجد طلبات تبادل مفتوحة حالياً.";
    }
  }

  Widget _requestCard(ExchangeRequestModel r) {
    final subtitle = "${r.user.displayName} · يريد ${r.wantedCategoryLabel}";
    return Card(
      child: ListTile(
        leading: const Icon(Icons.swap_horiz),
        title: Text(r.offeredService.title),
        subtitle: widget.mode == _RequestListMode.interests
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(subtitle),
                  const SizedBox(height: 4),
                  _ratingLine(r),
                ],
              )
            : Text(subtitle),
        trailing: _statusChip(r.status),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  widget.detailBuilder?.call(r) ??
                  ExchangeRequestDetailScreen(request: r),
            ),
          ).then((_) => refresh());
        },
      ),
    );
  }

  /// The rating of the service offered in return (not the owner's profile).
  Widget _ratingLine(ExchangeRequestModel r) {
    final rating = r.offeredServiceRating;
    if (rating == null) {
      return const Text(
        "لا توجد تقييمات للخدمة بعد",
        style: TextStyle(fontSize: 12, color: Colors.grey),
      );
    }
    return Row(
      children: [
        const Icon(Icons.star_rounded, size: 16, color: Colors.amber),
        const SizedBox(width: 4),
        Text(
          "${rating.toStringAsFixed(1)} (${r.offeredServiceReviewCount} تقييم)",
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Widget _statusChip(String status) {
    Color color;
    switch (status) {
      case 'open':
        color = Colors.orange;
        break;
      case 'matched':
        color = Colors.green;
        break;
      default:
        color = Colors.grey;
    }
    return Chip(
      // The internal status ('open', ...) decides the colour; the user sees
      // its Arabic label.
      label: Text(
        exchangeRequestStatusLabel(status),
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      backgroundColor: color,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _ProposalList extends StatefulWidget {
  final bool sent;
  final ExchangeService? exchangeService;
  final Widget Function(ExchangeRequestModel request)? detailBuilder;

  const _ProposalList({
    super.key,
    required this.sent,
    this.exchangeService,
    this.detailBuilder,
  });

  @override
  State<_ProposalList> createState() => _ProposalListState();
}

class _ProposalListState extends State<_ProposalList> {
  /// Rows per request. The backend's own default is 20, its ceiling 100.
  static const _pageSize = 20;

  late final ExchangeService _exchange =
      widget.exchangeService ?? ExchangeService();

  final List<ExchangeProposalModel> _proposals = [];
  final Set<int> _shownIds = {};

  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _nextPageError;
  bool _hasNext = false;
  int _page = 1;

  /// Bumped by every reload, so a page still in flight when the list is
  /// refreshed is dropped instead of appending to the new list. The sent
  /// and received tabs are separate states, so their pages, generations
  /// and errors are separate too.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// Loads page 1 from scratch. Used on open, on pull-to-refresh, and
  /// after coming back from a request's details, where a proposal may
  /// have been accepted or rejected.
  Future<void> _reload() async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _nextPageError = null;
    });
    try {
      final result = await _exchange.listMyProposals(
        sent: widget.sent,
        page: 1,
        pageSize: _pageSize,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _proposals
          ..clear()
          ..addAll(result.items);
        _shownIds
          ..clear()
          ..addAll(result.items.map((p) => p.id));
        _page = result.page;
        _hasNext = result.hasNext;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadNextPage() async {
    if (_loading || _loadingMore || !_hasNext || _nextPageError != null) return;
    final requestId = _requestId;
    setState(() => _loadingMore = true);

    try {
      final result = await _exchange.listMyProposals(
        sent: widget.sent,
        page: _page + 1,
        pageSize: _pageSize,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        for (final proposal in result.items) {
          if (_shownIds.add(proposal.id)) _proposals.add(proposal);
        }
        _page = result.page;
        _hasNext = result.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _nextPageError = errorText(e);
        _loadingMore = false;
      });
    }
  }

  void _retryNextPage() {
    setState(() => _nextPageError = null);
    _loadNextPage();
  }

  void refresh() => _reload();

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(onRefresh: _reload, child: _buildBody());
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Center(child: Text(_error!)),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton(
              onPressed: _reload,
              child: const Text("إعادة المحاولة"),
            ),
          ),
        ],
      );
    }
    if (_proposals.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Center(
            child: Text(
              widget.sent
                  ? "لم ترسل أي اقتراح بعد."
                  : "لم يصلك أي اقتراح بعد.",
            ),
          ),
        ],
      );
    }
    final hasFooter = _hasNext || _nextPageError != null;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 90),
      itemCount: _proposals.length + (hasFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, i) =>
          i == _proposals.length ? _footer() : _proposalCard(_proposals[i]),
    );
  }

  Widget _footer() {
    if (_nextPageError != null) {
      return Column(
        children: [
          Text(_nextPageError!, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _retryNextPage,
            child: const Text("إعادة المحاولة"),
          ),
        ],
      );
    }
    if (!_loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadNextPage());
    }
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: CircularProgressIndicator(),
      ),
    );
  }

  Widget _proposalCard(ExchangeProposalModel p) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.local_offer_outlined),
        title: Text(
          widget.sent
              ? "عرضت: ${p.proposedService.title}"
              : "${p.proposer.displayName} عرض: ${p.proposedService.title}",
        ),
        subtitle: Text("مقابل: ${p.request.offeredService.title}"),
        trailing: Text(
          exchangeProposalStatusLabel(p.status),
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: p.isPending ? Colors.orange.shade800 : null,
          ),
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  widget.detailBuilder?.call(p.request) ??
                  ExchangeRequestDetailScreen(request: p.request),
            ),
          ).then((_) => refresh());
        },
      ),
    );
  }
}
