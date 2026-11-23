import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/arabic_text.dart';

/// What the governorate picker returned. A wrapper so "chose «كل المدن»"
/// (city == null) is told apart from "closed without choosing" (no result).
class CityChoice {
  const CityChoice(this.city);
  final String? city;
}

/// A form field for the governorate (المحافظة / المدينة) list.
///
/// Tapping it opens a compact centred dialog (see [showCityPicker]) instead
/// of a full-height dropdown. [cities] are shown exactly as given — same
/// names, same order as the backend's `/cities` list.
///
/// When [allLabel] is set (the search filter), an extra first choice with
/// that label stands for «no filter» and reports `null`.
class CityPickerField extends StatelessWidget {
  const CityPickerField({
    super.key,
    required this.cities,
    required this.selected,
    required this.onChanged,
    this.hint = 'المدينة',
    this.prefixIcon,
    this.allLabel,
  });

  final List<String> cities;
  final String? selected;
  final ValueChanged<String?> onChanged;
  final String hint;
  final IconData? prefixIcon;
  final String? allLabel;

  Future<void> _open(BuildContext context) async {
    final choice = await showCityPicker(
      context,
      cities: cities,
      selected: selected,
      allLabel: allLabel,
    );
    if (choice != null) onChanged(choice.city);
  }

  @override
  Widget build(BuildContext context) {
    final shown = selected ?? allLabel;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _open(context),
      child: InputDecorator(
        isEmpty: shown == null,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: prefixIcon == null ? null : Icon(prefixIcon),
          suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        child: shown == null
            ? null
            : Text(shown, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// Opens the governorate dialog. Resolves to the choice, or to null when it
/// is closed without choosing (tap outside, back button, ✕).
Future<CityChoice?> showCityPicker(
  BuildContext context, {
  required List<String> cities,
  String? selected,
  String? allLabel,
}) {
  return showDialog<CityChoice>(
    context: context,
    builder: (_) => _CityPickerDialog(
      cities: cities,
      selected: selected,
      allLabel: allLabel,
    ),
  );
}

class _CityPickerDialog extends StatefulWidget {
  const _CityPickerDialog({
    required this.cities,
    required this.selected,
    required this.allLabel,
  });

  final List<String> cities;
  final String? selected;
  final String? allLabel;

  @override
  State<_CityPickerDialog> createState() => _CityPickerDialogState();
}

class _CityPickerDialogState extends State<_CityPickerDialog> {
  static const double _rowExtent = 50;

  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // The list is longer than the box: if the current choice is below the
    // visible part, open with it centred in view.
    final index = _entries.indexWhere((e) => e.isSelected);
    if (index >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final position = _scroll.position;
        final top = index * _rowExtent;
        if (top + _rowExtent <= position.viewportDimension) return;
        final target = top - (position.viewportDimension - _rowExtent) / 2;
        _scroll.jumpTo(target.clamp(0.0, position.maxScrollExtent));
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<_Entry> get _entries {
    final words = normalizeArabicForSearch(_query)
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    return [
      if (widget.allLabel != null && words.isEmpty)
        _Entry(null, widget.allLabel!, isSelected: widget.selected == null),
      for (final c in widget.cities)
        if (words.every((w) => normalizeArabicForSearch(c).contains(w)))
          _Entry(c, c, isSelected: c == widget.selected),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final screen = MediaQuery.sizeOf(context);
    final entries = _entries;

    return Dialog(
      key: const Key('city-picker-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 360,
          maxHeight: math.min(480, screen.height * 0.7),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 14, 8, 6),
              child: Row(
                children: [
                  Icon(
                    Icons.location_on_outlined,
                    size: 22,
                    color: dark ? AppColors.darkText : scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'اختر المحافظة',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'إغلاق',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                key: const Key('city-picker-search'),
                controller: _search,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'ابحث عن محافظة...',
                  fillColor: dark ? AppColors.darkField : Colors.grey.shade100,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: dark ? Colors.white54 : AppColors.primary,
                      width: 1.2,
                    ),
                  ),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  prefixIconConstraints: const BoxConstraints(minWidth: 40),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'مسح',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
            ),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Text(
                  'لا توجد محافظة بهذا الاسم.',
                  textAlign: TextAlign.center,
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  controller: _scroll,
                  shrinkWrap: true,
                  itemExtent: _rowExtent,
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  itemCount: entries.length,
                  itemBuilder: (context, i) => _tile(context, entries[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, _Entry entry) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final highlight = dark
        ? AppColors.darkPrimary.withValues(alpha: 0.45)
        : scheme.primary.withValues(alpha: 0.07);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: entry.isSelected ? highlight : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: Key('city-option-${entry.value ?? 'all'}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.pop(context, CityChoice(entry.value)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight:
                          entry.isSelected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (entry.isSelected)
                  Icon(
                    Icons.check_circle_rounded,
                    size: 20,
                    color: dark ? AppColors.darkText : scheme.primary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Entry {
  const _Entry(this.value, this.label, {required this.isSelected});
  final String? value;
  final String label;
  final bool isSelected;
}
