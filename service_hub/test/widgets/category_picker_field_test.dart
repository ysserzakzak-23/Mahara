import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/utils/arabic_text.dart';
import 'package:service_hub/features/service/data/service_models.dart';
import 'package:service_hub/shared/widgets/category_picker_field.dart';

ServiceCategory _cat(int id, String name, {bool other = false}) =>
    ServiceCategory(id: id, name: name, isOther: other);

final _categories = [
  _cat(1, 'سباكة'),
  _cat(2, 'كهرباء'),
  _cat(3, 'إلكترونيات'),
  _cat(4, 'صيانة جوالات'),
  _cat(5, 'صيانة حواسيب'),
  _cat(6, 'تصميم وجرافيك'),
  _cat(9, 'أخرى', other: true),
];

class _Host extends StatefulWidget {
  const _Host({this.initial, required this.picks});
  final int? initial;
  final List<int> picks;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int? _id;

  @override
  void initState() {
    super.initState();
    _id = widget.initial;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: CategoryPickerField(
              categories: _categories,
              selectedId: _id,
              onChanged: (id) {
                widget.picks.add(id);
                setState(() => _id = id);
              },
            ),
          ),
        ),
      );
}

Future<List<int>> _pump(WidgetTester tester, {int? initial}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final picks = <int>[];
  await tester.pumpWidget(_Host(initial: initial, picks: picks));
  return picks;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byType(CategoryPickerField));
  await tester.pumpAndSettle();
}

Finder get _searchBox => find.widgetWithText(TextField, 'ابحث عن مهنة...');

void main() {
  testWidgets('shows the hint when nothing is chosen', (tester) async {
    await _pump(tester);
    expect(find.text('التصنيف'), findsOneWidget);
  });

  testWidgets('shows the chosen trade by name', (tester) async {
    await _pump(tester, initial: 2);
    expect(find.text('كهرباء'), findsOneWidget);
  });

  testWidgets('opens a sheet with a search box and every trade', (tester) async {
    await _pump(tester);
    await _open(tester);

    expect(_searchBox, findsOneWidget);
    for (final name in ['سباكة', 'كهرباء', 'إلكترونيات', 'صيانة جوالات', 'أخرى']) {
      expect(find.text(name), findsOneWidget);
    }
  });

  testWidgets('"أخرى" is always the last entry', (tester) async {
    await _pump(tester);
    await _open(tester);

    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('تصميم وجرافيك'), lessThan(y('أخرى')));
    expect(y('سباكة'), lessThan(y('أخرى')));
  });

  testWidgets('typing narrows the list', (tester) async {
    await _pump(tester);
    await _open(tester);

    await tester.enterText(_searchBox, 'صيانة');
    await tester.pumpAndSettle();

    expect(find.text('صيانة جوالات'), findsOneWidget);
    expect(find.text('صيانة حواسيب'), findsOneWidget);
    expect(find.text('سباكة'), findsNothing);
    expect(find.text('كهرباء'), findsNothing);
  });

  testWidgets('spelling variants match (ا for إ, ه for ة)', (tester) async {
    await _pump(tester);
    await _open(tester);

    // typed without the hamza, as most people do
    await tester.enterText(_searchBox, 'الكترونيات');
    await tester.pumpAndSettle();
    expect(find.text('إلكترونيات'), findsOneWidget);
    expect(find.text('سباكة'), findsNothing);

    await tester.enterText(_searchBox, 'سباكه');
    await tester.pumpAndSettle();
    expect(find.text('سباكة'), findsOneWidget);
  });

  testWidgets('several words must all be present', (tester) async {
    await _pump(tester);
    await _open(tester);

    await tester.enterText(_searchBox, 'صيانة جوالات');
    await tester.pumpAndSettle();
    // (the typed text is also a Text widget, so look at the list rows only)
    expect(find.widgetWithText(ListTile, 'صيانة جوالات'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'صيانة حواسيب'), findsNothing);
  });

  testWidgets('"أخرى" stays available when nothing matches', (tester) async {
    await _pump(tester);
    await _open(tester);

    await tester.enterText(_searchBox, 'بيطري');
    await tester.pumpAndSettle();

    expect(find.textContaining('لم نجد مهنة بهذا الاسم'), findsOneWidget);
    expect(find.text('أخرى'), findsOneWidget);
    expect(find.text('سباكة'), findsNothing);
  });

  testWidgets('the clear button restores the full list', (tester) async {
    await _pump(tester);
    await _open(tester);

    await tester.enterText(_searchBox, 'كهر');
    await tester.pumpAndSettle();
    expect(find.text('سباكة'), findsNothing);

    await tester.tap(find.byTooltip('مسح'));
    await tester.pumpAndSettle();
    expect(find.text('سباكة'), findsOneWidget);
    expect(find.text('كهرباء'), findsOneWidget);
  });

  testWidgets('tapping a trade picks it and closes the sheet', (tester) async {
    final picks = await _pump(tester);
    await _open(tester);

    await tester.tap(find.text('كهرباء'));
    await tester.pumpAndSettle();

    expect(picks, [2]);
    expect(_searchBox, findsNothing);
    expect(find.text('كهرباء'), findsOneWidget); // now shown in the field
  });

  testWidgets('the other category can be picked after a failed search',
      (tester) async {
    final picks = await _pump(tester);
    await _open(tester);

    await tester.enterText(_searchBox, 'بيطري');
    await tester.pumpAndSettle();
    await tester.tap(find.text('أخرى'));
    await tester.pumpAndSettle();

    expect(picks, [9]);
  });

  testWidgets('the current choice is ticked in the sheet', (tester) async {
    await _pump(tester, initial: 1);
    await _open(tester);

    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('dismissing the sheet changes nothing', (tester) async {
    final picks = await _pump(tester, initial: 1);
    await _open(tester);

    await tester.tapAt(const Offset(10, 10)); // the barrier above the sheet
    await tester.pumpAndSettle();

    expect(picks, isEmpty);
    expect(find.text('سباكة'), findsOneWidget);
  });

  group('normalizeArabicForSearch', () {
    test('unifies the usual spelling variants', () {
      expect(normalizeArabicForSearch('إلكترونيات'), 'الكترونيات');
      expect(normalizeArabicForSearch('سباكة'), 'سباكه');
      expect(normalizeArabicForSearch('أخرى'), 'اخري');
      expect(normalizeArabicForSearch('سَبّاك'), 'سباك');
    });
  });
}
