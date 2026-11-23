import '../../../core/api/api_client.dart';
import '../../../core/api/paged_result.dart';
import 'exchange_models.dart';

/// Exchange Request / Proposal access against the FastAPI backend.
/// See backend/app/routers/exchange.py.
class ExchangeService {
  ExchangeService({ApiClient? apiClient}) : _api = apiClient ?? ApiClient.shared;

  final ApiClient _api;

  /// POST /exchange-requests — opens a new request for one of the current
  /// user's own services.
  Future<ExchangeRequestModel> createRequest({
    required int offeredServiceId,
    required int wantedCategoryId,
    String? wantedCustomCategoryLabel,
  }) async {
    final json = await _api.post('/exchange-requests', body: {
      'offered_service_id': offeredServiceId,
      'wanted_category_id': wantedCategoryId,
      if (wantedCustomCategoryLabel != null)
        'wanted_custom_category_label': wantedCustomCategoryLabel,
    });
    return ExchangeRequestModel.fromJson(json as Map<String, dynamic>);
  }

  /// GET /exchange-requests — public browse list of every open request.
  ///
  /// [excludeUserId] leaves that user's own requests out, which is what
  /// the Browse tab wants: your requests live under «طلباتي» and you
  /// cannot propose to yourself. The id has to be passed because this call
  /// carries no token (the list is public), so the server has no identity
  /// to take it from. Omitted, the whole list comes back as it always did.
  Future<PagedResult<ExchangeRequestModel>> listOpenRequests({
    int? excludeUserId,
    int? page,
    int? pageSize,
  }) async {
    final path = _withQuery('/exchange-requests', {
      if (excludeUserId != null) 'exclude_user_id': '$excludeUserId',
      ..._pageQuery(page, pageSize),
    });
    final json = await _api.get(path, auth: false);
    return parsePagedResponse(json, ExchangeRequestModel.fromJson);
  }

  /// GET /exchange-requests/search?q= — smart Arabic search over the Browse
  /// list (every open request, any category), best match first. Same engine
  /// as the main search page, but the results are exchange requests. The
  /// token is sent when there is one so the server leaves out my own.
  Future<PagedResult<ExchangeRequestModel>> searchRequests(
    String query, {
    int? page,
    int? pageSize,
  }) async {
    final path = _withQuery('/exchange-requests/search', {
      'q': query.trim(),
      ..._pageQuery(page, pageSize),
    });
    return parsePagedResponse(
      await _api.get(path),
      ExchangeRequestModel.fromRankedJson,
    );
  }

  /// GET /exchange-requests/interests — «اهتماماتي»: open requests from other
  /// users who want a service I offer, sorted by the offered service's
  /// rating (highest first). With [query], smart-searches within that set.
  Future<PagedResult<ExchangeRequestModel>> listInterests({
    String? query,
    int? page,
    int? pageSize,
  }) async {
    final q = query?.trim() ?? '';
    final path = _withQuery('/exchange-requests/interests', {
      if (q.isNotEmpty) 'q': q,
      ..._pageQuery(page, pageSize),
    });
    return parsePagedResponse(
      await _api.get(path),
      ExchangeRequestModel.fromRankedJson,
    );
  }

  /// `page`/`page_size`, and nothing at all when neither is asked for —
  /// that absence is what keeps the legacy bare-array response.
  Map<String, String> _pageQuery(int? page, int? pageSize) => {
        if (page != null) 'page': '$page',
        if (pageSize != null) 'page_size': '$pageSize',
      };

  String _withQuery(String path, Map<String, String> query) {
    if (query.isEmpty) return path;
    final encoded = query.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$path?$encoded';
  }

  /// GET /exchange-requests/me — the current user's own requests
  /// (any status).
  Future<PagedResult<ExchangeRequestModel>> listMyRequests({
    int? page,
    int? pageSize,
  }) async {
    final path = _withQuery('/exchange-requests/me', _pageQuery(page, pageSize));
    return parsePagedResponse(
      await _api.get(path),
      ExchangeRequestModel.fromJson,
    );
  }

  /// GET /exchange-requests/{id}/matches — runs the direct-matching
  /// algorithm. Only the request's own owner may call this.
  Future<List<DirectMatch>> matchesForRequest(int requestId) async {
    final json = await _api.get('/exchange-requests/$requestId/matches');
    return (json as List)
        .map((e) => DirectMatch.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// DELETE /exchange-requests/{id} — withdraws the current user's own
  /// open request.
  Future<void> closeRequest(int requestId) {
    return _api.delete('/exchange-requests/$requestId');
  }

  /// POST /exchange-requests/{id}/proposals — sends a concrete proposal
  /// (one of the current user's own services) to a request's owner.
  Future<ExchangeProposalModel> createProposal({
    required int requestId,
    required int proposedServiceId,
    String? message,
  }) async {
    final json = await _api.post('/exchange-requests/$requestId/proposals', body: {
      'proposed_service_id': proposedServiceId,
      if (message != null && message.isNotEmpty) 'message': message,
    });
    return ExchangeProposalModel.fromJson(json as Map<String, dynamic>);
  }

  /// GET /exchange-requests/{id}/proposals — the proposals on one request.
  ///
  /// The backend decides what this contains: every proposal on the request
  /// if it is mine, otherwise only the ones I sent to it. That is the same
  /// visibility the detail screen used to assemble by reading
  /// [listMyProposals] and discarding other requests' rows, except the
  /// discarding now happens in the query.
  Future<List<ExchangeProposalModel>> proposalsForRequest(int requestId) async {
    final json = await _api.get('/exchange-requests/$requestId/proposals');
    return (json as List)
        .map((e) => ExchangeProposalModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /exchange-proposals/me — [sent]=true: proposals I sent.
  /// [sent]=false: proposals received on my own requests.
  ///
  /// Still what the Exchange hub's two proposal tabs read: they are lists
  /// across every request, not one request's.
  Future<PagedResult<ExchangeProposalModel>> listMyProposals({
    required bool sent,
    int? page,
    int? pageSize,
  }) async {
    final path = _withQuery('/exchange-proposals/me', {
      'sent': '$sent',
      ..._pageQuery(page, pageSize),
    });
    return parsePagedResponse(
      await _api.get(path),
      ExchangeProposalModel.fromJson,
    );
  }

  /// POST /exchange-proposals/{id}/accept
  Future<ExchangeProposalModel> acceptProposal(int proposalId) async {
    final json = await _api.post('/exchange-proposals/$proposalId/accept');
    return ExchangeProposalModel.fromJson(json as Map<String, dynamic>);
  }

  /// POST /exchange-proposals/{id}/reject
  Future<ExchangeProposalModel> rejectProposal(int proposalId) async {
    final json = await _api.post('/exchange-proposals/$proposalId/reject');
    return ExchangeProposalModel.fromJson(json as Map<String, dynamic>);
  }
}
