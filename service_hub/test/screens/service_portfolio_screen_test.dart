import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/upload_service.dart';
import 'package:service_hub/features/service/data/portfolio_service.dart';
import 'package:service_hub/features/service/service_portfolio_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fakes.dart';
import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

Map<String, dynamic> _photo(int id) => {'id': id, 'image_url': '/uploads/p$id.jpg', 'caption': null, 'display_order': 0};

RoutedBackend _backend({List<Map<String, dynamic>>? photos, Map<String, Reply> extra = const {}}) =>
    RoutedBackend({
      'GET /services/100/portfolio': Reply(photos ?? []),
      'POST /uploads/image': const Reply({'url': '/uploads/new.png'}),
      'POST /services/100/portfolio': Reply(_photo(9), status: 201),
      ...extra,
    });

Future<void> _open(WidgetTester tester, RoutedBackend backend, {FakeImagePicker? picker}) async {
  useTallScreen(tester);
  final api = apiFor(backend);
  await tester.pumpWidget(MaterialApp(
    home: ServicePortfolioScreen(
      serviceId: 100,
      serviceTitle: 'Fix pipes',
      portfolioService: PortfolioService(apiClient: api),
      uploadService: UploadService(apiClient: api),
      imagePicker: picker ?? FakeImagePicker(),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  testWidgets('title shows the service name', (tester) async {
    await _open(tester, _backend());
    expect(find.text('Fix pipes — أعمال سابقة'), findsOneWidget);
  });

  testWidgets('empty state explains how to add photos', (tester) async {
    await _open(tester, _backend());
    expect(find.textContaining('لا توجد صور أعمال سابقة بعد'), findsOneWidget);
  });

  testWidgets('shows one grid cell per photo', (tester) async {
    await _open(tester, _backend(photos: [_photo(1), _photo(2), _photo(3)]));

    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(3));
    expect(find.byIcon(Icons.close), findsNWidgets(3));
  });

  testWidgets('shows the error when loading fails', (tester) async {
    await _open(
      tester,
      _backend(extra: {'GET /services/100/portfolio': const Reply({'detail': 'boom'}, status: 500)}),
    );
    expect(find.text('boom'), findsOneWidget);
  });

  group('adding a photo', () {
    testWidgets('uploads the image, attaches it to the service and reloads', (tester) async {
      final backend = _backend();
      await _open(tester, backend, picker: FakeImagePicker(fakeImageFile()));

      await tester.tap(find.byIcon(Icons.add_a_photo));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /uploads/image'), 1);
      expect(backend.lastBodyOf('POST /services/100/portfolio'), containsPair('image_url', '/uploads/new.png'));
      expect(backend.callsTo('GET /services/100/portfolio'), 2);
    });

    testWidgets('cancelling the gallery does nothing', (tester) async {
      final backend = _backend();
      await _open(tester, backend, picker: FakeImagePicker(null));

      await tester.tap(find.byIcon(Icons.add_a_photo));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /uploads/image'), 0);
      expect(backend.callsTo('GET /services/100/portfolio'), 1);
    });

    testWidgets('the button shows a spinner and is disabled during the upload', (tester) async {
      final backend = _backend();
      await _open(tester, backend, picker: FakeImagePicker(fakeImageFile()));
      backend.gate = Completer<void>();

      await tester.tap(find.byIcon(Icons.add_a_photo));
      await tester.pump();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<FloatingActionButton>(find.byType(FloatingActionButton)).onPressed, isNull);

      backend.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.add_a_photo), findsOneWidget);
    });

    testWidgets('an upload failure is shown and nothing is attached', (tester) async {
      final backend = _backend(extra: {
        'POST /uploads/image': const Reply({'detail': 'Unsupported image type'}, status: 400),
      });
      await _open(tester, backend, picker: FakeImagePicker(fakeImageFile()));

      await tester.tap(find.byIcon(Icons.add_a_photo));
      await pumpFrames(tester);

      expect(find.text('Unsupported image type'), findsOneWidget);
      expect(backend.callsTo('POST /services/100/portfolio'), 0);
    });

    testWidgets('a refused attach (not your service) is shown', (tester) async {
      final backend = _backend(extra: {
        'POST /services/100/portfolio': const Reply({'detail': 'You do not own this service'}, status: 403),
      });
      await _open(tester, backend, picker: FakeImagePicker(fakeImageFile()));

      await tester.tap(find.byIcon(Icons.add_a_photo));
      await pumpFrames(tester);

      expect(find.text('You do not own this service'), findsOneWidget);
    });
  });

  group('removing a photo', () {
    testWidgets('deletes it and reloads', (tester) async {
      final backend = _backend(photos: [_photo(5)], extra: {
        'DELETE /services/100/portfolio/5': const Reply(null, status: 204),
      });
      await _open(tester, backend);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(backend.callsTo('DELETE /services/100/portfolio/5'), 1);
      expect(backend.callsTo('GET /services/100/portfolio'), 2);
    });

    testWidgets('a refusal is shown', (tester) async {
      final backend = _backend(photos: [_photo(5)], extra: {
        'DELETE /services/100/portfolio/5': const Reply({'detail': 'Not allowed'}, status: 403),
      });
      await _open(tester, backend);

      await tester.tap(find.byIcon(Icons.close));
      await pumpFrames(tester);

      expect(find.text('Not allowed'), findsOneWidget);
    });
  });
}
