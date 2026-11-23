import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/theme/app_colors.dart';
import 'package:service_hub/core/theme/app_theme.dart';
import 'package:service_hub/shared/widgets/city_picker_field.dart';

/// The backend's governorate list (backend/app/core/constants.py), in order.
const _governorates = [
  'دمشق',
  'ريف دمشق',
  'حلب',
  'حمص',
  'حماة',
  'اللاذقية',
  'طرطوس',
  'إدلب',
  'درعا',
  'السويداء',
  'القنيطرة',
  'دير الزور',
  'الرقة',
  'الحسكة',
];

final _dialog = find.byKey(const Key('city-picker-dialog'));
Finder _option(String? city) => find.byKey(Key('city-option-${city ?? 'all'}'));
// The list's own Scrollable (the search TextField has one too).
final _list = find
    .descendant(
      of: find.descendant(of: _dialog, matching: find.byType(ListView)),
      matching: find.byType(Scrollable),
    )
    .first;

/// A page holding one CityPickerField whose value is kept in page state,
/// like the real screens do. [changes] records every onChanged call.
class _Host extends StatefulWidget {
  const _Host({required this.changes, this.initial, this.allLabel});
  final List<String?> changes;
  final String? initial;
  final String? allLabel;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String? _city = widget.initial;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              CityPickerField(
                cities: _governorates,
                selected: _city,
                allLabel: widget.allLabel,
                onChanged: (c) {
                  widget.changes.add(c);
                  setState(() => _city = c);
                },
              ),
              Text('VALUE: ${_city ?? '-'}'),
            ],
          ),
        ),
      );
}

Future<List<String?>> _pump(
  WidgetTester tester, {
  String? initial,
  String? allLabel,
  ThemeMode mode = ThemeMode.light,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final changes = <String?>[];
  await tester.pumpWidget(MaterialApp(
    theme: appTheme,
    darkTheme: darkAppTheme,
    themeMode: mode,
    builder: (context, child) =>
        Directionality(textDirection: TextDirection.rtl, child: child!),
    home: _Host(changes: changes, initial: initial, allLabel: allLabel),
  ));
  return changes;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byType(CityPickerField));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens a compact dialog (not full screen) titled «اختر المحافظة»',
      (tester) async {
    await _pump(tester);
    await _open(tester);

    expect(_dialog, findsOneWidget);
    expect(find.text('اختر المحافظة'), findsOneWidget);
    final box = tester.getRect(find.descendant(of: _dialog, matching: find.byType(Material)).first);
    expect(box.width, lessThanOrEqualTo(360));
    expect(box.height, lessThanOrEqualTo(480));
    expect(box.height, lessThan(844 * 0.75));
    // Centred, with the page still visible around it.
    expect(box.center.dx, closeTo(390 / 2, 1));
    expect(box.top, greaterThan(24));
  });

  testWidgets('keeps every governorate, same names, same order (scrolls inside the box)',
      (tester) async {
    await _pump(tester);
    await _open(tester);

    String? previous;
    for (final city in _governorates) {
      await tester.scrollUntilVisible(_option(city), 50, scrollable: _list);
      final top = tester.getTopLeft(_option(city)).dy;
      if (previous != null && _option(previous).evaluate().isNotEmpty) {
        expect(top, greaterThan(tester.getTopLeft(_option(previous)).dy),
            reason: '$city must come after $previous');
      }
      expect(find.descendant(of: _option(city), matching: find.text(city)), findsOneWidget);
      previous = city;
    }
    expect(previous, _governorates.last);
    // Nothing extra (no «كل المدن» unless asked for).
    expect(_option(null), findsNothing);
  });

  testWidgets('tapping a governorate returns it to the page and closes the dialog',
      (tester) async {
    final changes = await _pump(tester);
    await _open(tester);

    await tester.tap(_option('حمص'));
    await tester.pumpAndSettle();

    expect(_dialog, findsNothing);
    expect(changes, ['حمص']);
    expect(find.text('VALUE: حمص'), findsOneWidget);
    expect(find.descendant(of: find.byType(CityPickerField), matching: find.text('حمص')),
        findsOneWidget);
  });

  testWidgets('closing without choosing (✕ or outside) changes nothing', (tester) async {
    final changes = await _pump(tester, initial: 'حلب');

    await _open(tester);
    await tester.tap(find.byTooltip('إغلاق'));
    await tester.pumpAndSettle();
    expect(_dialog, findsNothing);

    await _open(tester);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(_dialog, findsNothing);

    expect(changes, isEmpty);
    expect(find.text('VALUE: حلب'), findsOneWidget);
  });

  testWidgets('the current governorate is highlighted and ticked, and scrolled into view',
      (tester) async {
    await _pump(tester, initial: 'الرقة'); // near the end of the list
    await _open(tester);

    expect(_option('الرقة').hitTestable(), findsOneWidget);
    expect(find.descendant(of: _option('الرقة'), matching: find.byIcon(Icons.check_circle_rounded)),
        findsOneWidget);
    expect(find.descendant(of: _dialog, matching: find.byIcon(Icons.check_circle_rounded)),
        findsOneWidget);

    Material tileOf(String c) =>
        tester.widget<Material>(find.ancestor(of: _option(c), matching: find.byType(Material)).first);
    expect(tileOf('الرقة').color, isNot(Colors.transparent));
    expect(tileOf('دير الزور').color, Colors.transparent);
    // RTL: the tick is on the left (end side) of the name.
    expect(tester.getCenter(find.byIcon(Icons.check_circle_rounded)).dx,
        lessThan(tester.getCenter(find.descendant(of: _option('الرقة'), matching: find.text('الرقة'))).dx));
  });

  testWidgets('the search box narrows the list, ignoring spelling variants', (tester) async {
    final changes = await _pump(tester);
    await _open(tester);

    await tester.enterText(find.byKey(const Key('city-picker-search')), 'دمشق');
    await tester.pumpAndSettle();
    expect(_option('دمشق'), findsOneWidget);
    expect(_option('ريف دمشق'), findsOneWidget);
    expect(_option('حلب'), findsNothing);

    // ه for ة and ا for إ still match.
    await tester.enterText(find.byKey(const Key('city-picker-search')), 'اللاذقيه');
    await tester.pumpAndSettle();
    expect(_option('اللاذقية'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('city-picker-search')), 'ادلب');
    await tester.pumpAndSettle();
    expect(_option('إدلب'), findsOneWidget);

    await tester.tap(_option('إدلب'));
    await tester.pumpAndSettle();
    expect(changes, ['إدلب']);
  });

  testWidgets('no match shows a short message; clearing brings the list back', (tester) async {
    await _pump(tester);
    await _open(tester);

    await tester.enterText(find.byKey(const Key('city-picker-search')), 'باريس');
    await tester.pumpAndSettle();
    expect(find.text('لا توجد محافظة بهذا الاسم.'), findsOneWidget);

    await tester.tap(find.byTooltip('مسح'));
    await tester.pumpAndSettle();
    expect(_option('دمشق'), findsOneWidget);
  });

  testWidgets('with allLabel (search filter): «كل المدن» comes first and means null',
      (tester) async {
    final changes = await _pump(tester, initial: 'حلب', allLabel: 'كل المدن');
    await _open(tester);

    expect(tester.getTopLeft(_option(null)).dy, lessThan(tester.getTopLeft(_option('دمشق')).dy));
    await tester.tap(_option(null));
    await tester.pumpAndSettle();

    expect(changes, [null]);
    expect(find.text('VALUE: -'), findsOneWidget);
    // The field then reads «كل المدن», as the old dropdown did.
    expect(find.descendant(of: find.byType(CityPickerField), matching: find.text('كل المدن')),
        findsOneWidget);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('${mode.name} mode: uses the app theme colours', (tester) async {
      await _pump(tester, mode: mode, initial: 'دمشق');
      await _open(tester);

      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      final ctx = tester.element(_dialog);
      expect(Theme.of(ctx).brightness,
          mode == ThemeMode.dark ? Brightness.dark : Brightness.light);
      // Dialog colour comes from the theme (darkCard in dark mode).
      expect(dialog.backgroundColor, isNull);
      final surface = tester.widget<Material>(
          find.descendant(of: _dialog, matching: find.byType(Material)).first);
      expect(surface.color,
          mode == ThemeMode.dark ? AppColors.darkCard : Theme.of(ctx).colorScheme.surfaceContainerHigh);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in const [Size(320, 480), Size(360, 640), Size(800, 1280)]) {
    testWidgets('fits at ${size.width.toInt()}x${size.height.toInt()} and still picks',
        (tester) async {
      final changes = await _pump(tester, size: size);
      await _open(tester);
      expect(tester.takeException(), isNull);

      final box = tester.getRect(find.descendant(of: _dialog, matching: find.byType(Material)).first);
      expect(box.bottom, lessThanOrEqualTo(size.height));
      expect(box.width, lessThanOrEqualTo(360));

      await tester.scrollUntilVisible(_option('الحسكة'), 50, scrollable: _list);
      await tester.ensureVisible(_option('الحسكة'));
      await tester.pumpAndSettle();
      expect(_option('الحسكة').hitTestable(), findsOneWidget);
      await tester.tap(_option('الحسكة'));
      await tester.pumpAndSettle();
      expect(changes, ['الحسكة']);
    });
  }
}
