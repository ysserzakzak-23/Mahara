import 'package:flutter/material.dart';

import '../../core/utils/arabic_text.dart';
import '../../features/service/data/service_models.dart';

/// A form field that picks one service category (trade) from a long list.
///
/// Tapping it opens a bottom sheet with a search box on top, so with 40+
/// trades nobody has to scroll: typing "كهر" or "الكترونيات" narrows the list
/// (spelling variants such as أ/ا, ة/ه, ى/ي are treated alike). The catch-all
/// «أخرى» category is always the last entry, whatever was typed.
///
/// [categories] should already be in the order to show; the "other" category
/// is moved to the end here regardless.
class CategoryPickerField extends StatelessWidget {
  const CategoryPickerField({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onChanged,
    this.hint = 'التصنيف',
  });

  final List<ServiceCategory> categories;
  final int? selectedId;
  final ValueChanged<int> onChanged;
  final String hint;

  ServiceCategory? get _selected {
    for (final c in categories) {
      if (c.id == selectedId) return c;
    }
    return null;
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _CategorySheet(
        categories: categories,
        selectedId: selectedId,
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _open(context),
      child: InputDecorator(
        isEmpty: selected == null,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: selected == null
            ? null
            : Text(selected.name, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _CategorySheet extends StatefulWidget {
  const _CategorySheet({required this.categories, required this.selectedId});

  final List<ServiceCategory> categories;
  final int? selectedId;

  @override
  State<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends State<_CategorySheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ServiceCategory> get _matches {
    final normal = widget.categories.where((c) => !c.isOther);
    final words = normalizeArabicForSearch(_query)
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return normal.toList();
    return normal.where((c) {
      final name = normalizeArabicForSearch(c.name);
      return words.every((w) => name.contains(w));
    }).toList();
  }

  ServiceCategory? get _other {
    for (final c in widget.categories) {
      if (c.isOther) return c;
    }
    return null;
  }

  Widget _tile(ServiceCategory c) => ListTile(
        title: Text(c.name),
        trailing: c.id == widget.selectedId ? const Icon(Icons.check) : null,
        onTap: () => Navigator.pop(context, c.id),
      );

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final available =
        media.size.height - media.viewInsets.bottom - media.padding.top - 24;
    final height = available < media.size.height * 0.8
        ? available
        : media.size.height * 0.8;

    final matches = _matches;
    final other = _other;
    final hasQuery = _query.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: height < 200 ? 200 : height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: 'ابحث عن مهنة...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'مسح',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final c in matches) _tile(c),
                  if (matches.isEmpty && hasQuery)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'لم نجد مهنة بهذا الاسم. اختر «أخرى» واكتب مهنتك.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (other != null) ...[
                    if (matches.isNotEmpty) const Divider(height: 1),
                    _tile(other),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
