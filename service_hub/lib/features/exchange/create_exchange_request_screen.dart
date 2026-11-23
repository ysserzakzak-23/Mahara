import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../core/storage/token_store.dart';
import '../service/data/catalog_service.dart';
import '../service/data/service_models.dart';
import 'data/exchange_service.dart';
import '../../core/utils/error_text.dart';
import '../../shared/widgets/category_picker_field.dart';

/// "اطلب" — opens a new ExchangeRequest: "I'm offering [one of my services]
/// and want something in [category] in return."
class CreateExchangeRequestScreen extends StatefulWidget {
  const CreateExchangeRequestScreen({
    super.key,
    this.tokenStore,
    this.catalogService,
    this.exchangeService,
  });

  /// Optional overrides, mainly so widget tests can inject a fake backend.
  final TokenStore? tokenStore;
  final CatalogService? catalogService;
  final ExchangeService? exchangeService;

  @override
  State<CreateExchangeRequestScreen> createState() =>
      _CreateExchangeRequestScreenState();
}

class _CreateExchangeRequestScreenState
    extends State<CreateExchangeRequestScreen> {
  late final TokenStore _tokenStore = widget.tokenStore ?? TokenStore();
  late final CatalogService _catalog =
      widget.catalogService ?? CatalogService();
  late final ExchangeService _exchange =
      widget.exchangeService ?? ExchangeService();
  final _wantedCustomCategoryLabelController = TextEditingController();

  late Future<_FormData> _formDataFuture;
  int? _offeredServiceId;
  int? _wantedCategoryId;
  bool _submitting = false;
  List<ServiceCategory> _categories = [];
  @override
  void initState() {
    super.initState();
    _formDataFuture = _loadFormData();
    _formDataFuture.then(
      (data) {
        if (mounted) setState(() => _categories = data.categories);
      },
      // The FutureBuilder shows the error; this only avoids a second,
      // unhandled-exception report for the same failure.
      onError: (_) {},
    );
  }

  ServiceCategory? get _selectedWantedCategory {
    for (final c in _categories) {
      if (c.id == _wantedCategoryId) return c;
    }
    return null;
  }

  @override
  void dispose() {
    _wantedCustomCategoryLabelController.dispose();
    super.dispose();
  }

  Future<_FormData> _loadFormData() async {
    // Only my id is needed to list my own services, and it is already in
    // the access token on the device — this used to fetch the whole
    // profile from /users/me for it. A null id means the token is missing
    // or unreadable, which the FutureBuilder below reports through the
    // error state it already had (errorText turns anything without a
    // user-facing message into the app's generic Arabic one).
    final myId = await _tokenStore.currentUserId;
    if (myId == null) {
      throw StateError('no readable user id in the stored access token');
    }
    final results = await Future.wait([
      _catalog.servicesByProvider(myId),
      _catalog.categories(),
    ]);
    return _FormData(
      myServices: results[0] as List<ServiceListItem>,
      categories: results[1] as List<ServiceCategory>,
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _submit() async {
    if (_offeredServiceId == null) {
      _showMessage('اختر إحدى خدماتك أولاً.');
      return;
    }
    if (_wantedCategoryId == null) {
      _showMessage('اختر الفئة التي تريد التبادل فيها.');
      return;
    }
    final wantedCustomCategoryLabel = _wantedCustomCategoryLabelController.text
        .trim();
    if (_selectedWantedCategory?.isOther == true &&
        wantedCustomCategoryLabel.isEmpty) {
      _showMessage('اكتب بالضبط ما تحتاجه.');
      return;
    }

    setState(() => _submitting = true);
    try {
      await _exchange.createRequest(
        offeredServiceId: _offeredServiceId!,
        wantedCategoryId: _wantedCategoryId!,
        wantedCustomCategoryLabel: _selectedWantedCategory?.isOther == true
            ? wantedCustomCategoryLabel
            : null,
      );
      if (!mounted) return;
      _showMessage('تم فتح طلب التبادل!');
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("طلب تبادل جديد"),
        titleSpacing: -2,
        backgroundColor: const Color.fromARGB(0, 77, 75, 75),
      ),
      body: FutureBuilder<_FormData>(
        future: _formDataFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text(errorText(snapshot.error)));
          }
          final data = snapshot.data!;
          if (data.myServices.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'يجب أن تملك خدمة منشورة قبل فتح طلب تبادل. '
                  'أضف خدمة من صفحتك الشخصية ثم عد إلى هنا.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "ماذا تريد أن تعرض؟",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                _boxed(
                  DropdownButtonFormField<int>(
                    initialValue: _offeredServiceId,
                    isExpanded: true,
                    items: [
                      for (final s in data.myServices)
                        DropdownMenuItem(value: s.id, child: Text(s.title)),
                    ],
                    onChanged: (value) =>
                        setState(() => _offeredServiceId = value),
                    decoration: const InputDecoration(hintText: "إحدى خدماتك"),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  "ماذا تريد بالمقابل؟",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                // The same searchable picker the "add service" form uses: with
                // 40+ trades, typing a few letters beats scrolling the whole
                // list. "Others" غير موجودة بترتيبها العادي — منحطها آخر شي،
                // والـ picker بيخليها آخر شي كمان لو طلعت نتيجة بحث.
                _boxed(
                  CategoryPickerField(
                    categories: [
                      for (final c in data.categories)
                        if (!c.isOther) c,
                      for (final c in data.categories)
                        if (c.isOther) c,
                    ],
                    selectedId: _wantedCategoryId,
                    onChanged: (id) => setState(() => _wantedCategoryId = id),
                    hint: "الفئة المطلوبة",
                  ),
                ),
                if (_selectedWantedCategory?.isOther == true) ...[
                  const SizedBox(height: 12),
                  _boxed(
                    TextField(
                      controller: _wantedCustomCategoryLabelController,
                      decoration: const InputDecoration(
                        hintText: "ما الذي تحتاجه بالضبط؟",
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
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
                      : const Text(
                          "فتح الطلب",
                          style: TextStyle(color: Colors.white),
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _boxed(Widget child) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: child,
    );
  }
}

class _FormData {
  final List<ServiceListItem> myServices;
  final List<ServiceCategory> categories;

  _FormData({required this.myServices, required this.categories});
}
