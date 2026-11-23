import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/storage/token_store.dart';

import 'fixtures.dart';

/// An ApiClient wired to a [RoutedBackend] instead of the real network.
ApiClient apiFor(RoutedBackend backend, {TokenStore? tokenStore}) => ApiClient(
      httpClient: backend.client,
      tokenStore: tokenStore ?? TokenStore(),
    );

/// The default test surface is 800x600, which makes tall forms overflow.
void useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Lets async work (fake HTTP, SharedPreferences) finish and shows snackbars,
/// without pumpAndSettle (which would also wait for the snackbar to vanish).
Future<void> pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Screens that show an avatar would try to download it with NetworkImage,
/// which fails (HTTP 400) inside flutter test. Strip the avatar URL.
Map<String, dynamic> withoutAvatar(Map<String, dynamic> provider) {
  // Copy into a Map<String, dynamic>: the literal in providerJson() is inferred
  // as Map<String, String>, which cannot hold a null.
  final profile = Map<String, dynamic>.from(provider['profile'] as Map);
  profile['avatar_url'] = null;
  provider['profile'] = profile;
  return provider;
}

/// An exchange request whose owner has no avatar (see [withoutAvatar]).
Map<String, dynamic> exchangeRequestNoAvatar({
  int id = 7,
  int ownerId = 10,
  String ownerName = 'Ahmad Ali',
  String status = 'open',
  String offeredTitle = 'Fix pipes',
  int offeredServiceId = 100,
  Map<String, dynamic>? wantedCategory,
  String? wantedLabel,
}) {
  final json = _exchangeBase(status, wantedCategory, wantedLabel);
  json['id'] = id;
  json['user'] = withoutAvatar(_provider(ownerId, ownerName));
  final offered = json['offered_service'] as Map<String, dynamic>;
  offered['title'] = offeredTitle;
  offered['id'] = offeredServiceId;
  return json;
}

Map<String, dynamic> exchangeProposalNoAvatar({
  int id = 3,
  String status = 'pending',
  String? message,
  int proposerId = 20,
  String proposerName = 'Sara Hassan',
  int proposedServiceId = 55,
  String proposedTitle = 'Painting',
  Map<String, dynamic>? request,
}) =>
    {
      'id': id,
      'status': status,
      'message': message,
      'proposer': withoutAvatar(_provider(proposerId, proposerName)),
      'proposed_service': _service(proposedServiceId, proposedTitle),
      'request': request ?? exchangeRequestNoAvatar(),
    };

Map<String, dynamic> _provider(int id, String name) => providerJson(id: id, name: name);

Map<String, dynamic> _service(int id, String title) =>
    serviceListItemJson(id: id)..['title'] = title;

Map<String, dynamic> _exchangeBase(
  String status,
  Map<String, dynamic>? wantedCategory,
  String? wantedLabel,
) =>
    exchangeRequestJson(
      status: status,
      wantedCategory: wantedCategory,
      wantedLabel: wantedLabel,
    );

/// Opens [builder]'s screen from a launcher page, so tests can check what
/// happens when the screen closes itself (Navigator.pop).
///
/// Optional: the app's real [theme] (used for both light and dark via
/// [themeMode]/[darkTheme]), right-to-left layout ([rtl]) and a phone
/// [size] instead of the default tall screen.
Future<void> openFromLauncher(
  WidgetTester tester,
  Widget Function(BuildContext context) builder, {
  ThemeData? theme,
  ThemeData? darkTheme,
  ThemeMode themeMode = ThemeMode.light,
  bool rtl = false,
  Size? size,
}) async {
  if (size == null) {
    useTallScreen(tester);
  } else {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    darkTheme: darkTheme,
    themeMode: themeMode,
    builder: rtl
        ? (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!)
        : null,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: builder)),
            child: const Text('OPEN'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
}

/// Add / edit service: the price field and the price-unit field share one
/// row, half each (RTL: price on the right), in identical shadowed boxes of
/// the same height.
void expectPriceAndUnitSideBySide(WidgetTester tester, {required double screenWidth}) {
  final price = find.widgetWithText(TextField, 'السعر (اختياري) (\$)');
  final unit = find.byKey(const Key('price-unit'));
  final row = find.byKey(const Key('price-row'));
  expect(find.descendant(of: row, matching: price), findsOneWidget);
  expect(find.descendant(of: row, matching: unit), findsOneWidget);

  // The shadowed box each one sits in (the screens' _boxed()).
  Finder boxOf(Finder f) => find
      .ancestor(
        of: f,
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            ((w.decoration as BoxDecoration).boxShadow?.isNotEmpty ?? false)),
      )
      .first;
  final priceBox = tester.getRect(boxOf(price));
  final unitBox = tester.getRect(boxOf(unit));

  expect(priceBox.top, closeTo(unitBox.top, 0.5));
  expect(priceBox.height, closeTo(unitBox.height, 0.5));
  expect(priceBox.width, closeTo(unitBox.width, 0.5));
  expect(priceBox.width, lessThan(screenWidth / 2));
  expect(tester.getRect(price).height, closeTo(tester.getRect(unit).height, 0.5));
  // RTL: the price is on the right, its unit on the left.
  expect(priceBox.left, greaterThan(unitBox.right));
  // Same box decoration (radius + shadow) on both.
  expect(tester.widget<Container>(boxOf(price)).decoration,
      tester.widget<Container>(boxOf(unit)).decoration);
  expect(tester.takeException(), isNull);
}

/// A SnackBar stays on screen for ~4 s and later ones wait in a queue, so a test
/// that triggers several different messages must dismiss each one first.
Future<void> clearSnackBars(WidgetTester tester) async {
  tester
      .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
      .clearSnackBars();
  await tester.pump();
}
