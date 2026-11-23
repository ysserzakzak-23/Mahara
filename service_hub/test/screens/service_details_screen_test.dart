import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/features/reviews/data/review_service.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:service_hub/features/service/service_details_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

Map<String, dynamic> _detail({
  bool remote = false,
  Map<String, dynamic>? category,
  String? label,
}) =>
    {
      'id': 100,
      'title': 'Fix pipes',
      'description': 'I fix all kinds of pipes',
      'price': '25.50',
      'price_unit': 'hour',
      'status': 'active',
      'is_remote': remote,
      'category': category ?? categoryJson(),
      'provider': withoutAvatar(providerJson()),
      'custom_category_label': label,
    };

Map<String, dynamic> _review(int id, int rating, String? comment, String name) => {
      'id': id,
      'rating': rating,
      'comment': comment,
      'reviewer': withoutAvatar(providerJson(id: 50 + id, name: name)),
    };

RoutedBackend _backend({
  Map<String, dynamic>? detail,
  List<Map<String, dynamic>> reviews = const [],
  Map<String, dynamic> summary = const {'average_rating': 0, 'review_count': 0},
  Map<String, Reply> extra = const {},
}) =>
    RoutedBackend({
      'GET /services/100': Reply(detail ?? _detail()),
      'GET /services/100/reviews': Reply(reviews),
      'GET /services/100/reviews/summary': Reply(summary),
      ...extra,
    });

Widget _app(RoutedBackend backend) {
  final api = apiFor(backend);
  return MaterialApp(
    home: ServiceDetailsScreen(
      serviceId: 100,
      catalogService: CatalogService(apiClient: api),
      reviewService: ReviewService(apiClient: api),
      bookingBuilder: (s) => Scaffold(body: Text('BOOKING ${s.id} ${s.title}')),
      providerBuilder: (id) => Scaffold(body: Text('PROVIDER $id')),
    ),
  );
}

Future<void> _open(WidgetTester tester, RoutedBackend backend) async {
  useTallScreen(tester);
  await tester.pumpWidget(_app(backend));
  await tester.pumpAndSettle();
}

Finder _inDialog(Finder matching) =>
    find.descendant(of: find.byType(AlertDialog), matching: matching);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  group('service info', () {
    testWidgets('shows a spinner, then the service', (tester) async {
      useTallScreen(tester);
      await tester.pumpWidget(_app(_backend()));
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      await tester.pumpAndSettle();

      expect(find.text('Fix pipes'), findsOneWidget);
      expect(find.text('بواسطة Ahmad Ali'), findsOneWidget);
      expect(find.text('سباكة'), findsOneWidget);
      expect(find.text('Damascus'), findsOneWidget);
      expect(find.text('I fix all kinds of pipes'), findsOneWidget);
      expect(find.text('25.50 \$ (بالساعة)'), findsOneWidget); // internal unit 'hour'
      expect(find.textContaining('hour'), findsNothing);
    });

    testWidgets('a missing service shows the server message', (tester) async {
      await _open(
        tester,
        _backend(extra: {
          'GET /services/100': const Reply({'detail': 'Service not found'}, status: 404),
        }),
      );
      expect(find.text('Service not found'), findsOneWidget);
      expect(find.text('احجز موعداً'), findsNothing);
    });

    testWidgets('remote services get a "عن بُعد" badge, others do not', (tester) async {
      await _open(tester, _backend(detail: _detail(remote: true)));
      expect(find.text('عن بُعد'), findsOneWidget);
    });

    testWidgets('no badge for on-site services', (tester) async {
      await _open(tester, _backend());
      expect(find.text('عن بُعد'), findsNothing);
    });

    testWidgets('"أخرى" services show the provider\'s own category label',
        (tester) async {
      await _open(
        tester,
        _backend(
          detail: _detail(
            category: categoryJson(id: 9, name: 'أخرى', isOther: true),
            label: 'Gardener',
          ),
        ),
      );
      expect(find.text('Gardener'), findsOneWidget);
      expect(find.text('أخرى'), findsNothing);
    });
  });

  group('navigation', () {
    testWidgets('Book Appointment opens the booking screen for this service',
        (tester) async {
      await _open(tester, _backend());

      await tester.tap(find.text('احجز موعداً'));
      await tester.pumpAndSettle();

      expect(find.text('BOOKING 100 Fix pipes'), findsOneWidget);
    });

    testWidgets('tapping the provider opens their profile', (tester) async {
      await _open(tester, _backend());

      await tester.tap(find.text('بواسطة Ahmad Ali'));
      await tester.pumpAndSettle();

      expect(find.text('PROVIDER 10'), findsOneWidget);
    });
  });

  group('reviews list', () {
    testWidgets('empty state', (tester) async {
      await _open(tester, _backend());
      expect(find.text('لا توجد تقييمات بعد.'), findsOneWidget);
    });

    testWidgets('shows each review with its comment and author', (tester) async {
      await _open(
        tester,
        _backend(
          reviews: [
            _review(1, 4, 'Great work', 'Sara Hassan'),
            _review(2, 2, null, 'Omar Khaled'),
          ],
        ),
      );

      expect(find.text('Great work'), findsOneWidget);
      expect(find.text('Sara Hassan'), findsOneWidget);
      expect(find.text('Omar Khaled'), findsOneWidget);
      expect(find.text('لا توجد تقييمات بعد.'), findsNothing);
    });

    testWidgets('shows the average rating when there are reviews', (tester) async {
      await _open(
        tester,
        _backend(
          reviews: [_review(1, 5, 'Top', 'Sara Hassan')],
          summary: const {'average_rating': 4.5, 'review_count': 2},
        ),
      );
      expect(find.text('4.5 (2 تقييم)'), findsOneWidget);
    });

    testWidgets('hides the rating line when there are no reviews', (tester) async {
      await _open(tester, _backend());
      expect(find.textContaining('تقييم)'), findsNothing);
    });

    testWidgets('a failed reviews request shows its error without hiding the service',
        (tester) async {
      await _open(
        tester,
        _backend(extra: {
          'GET /services/100/reviews': const Reply({'detail': 'reviews down'}, status: 500),
        }),
      );
      expect(find.text('reviews down'), findsOneWidget);
      expect(find.text('Fix pipes'), findsOneWidget);
    });
  });

  group('leaving a review', () {
    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.text('أضف تقييماً'));
      await tester.pumpAndSettle();
    }

    testWidgets('submits the chosen stars and trimmed comment, then reloads',
        (tester) async {
      final backend = _backend(extra: {
        'POST /services/100/reviews': Reply(_review(7, 3, 'Nice', 'Me'), status: 201),
      });
      await _open(tester, backend);
      await openDialog(tester);

      await tester.tap(_inDialog(find.byType(IconButton)).at(2)); // 3 stars
      await tester.enterText(_inDialog(find.byType(TextField)), '  Nice  ');
      await tester.tap(find.widgetWithText(ElevatedButton, 'إرسال'));
      await pumpFrames(tester);

      expect(backend.lastBodyOf('POST /services/100/reviews'), {'rating': 3, 'comment': 'Nice'});
      expect(find.text('شكراً على تقييمك!'), findsOneWidget);
      expect(backend.callsTo('GET /services/100/reviews'), 2);
    });

    testWidgets('defaults to 5 stars and omits an empty comment', (tester) async {
      final backend = _backend(extra: {
        'POST /services/100/reviews': Reply(_review(7, 5, null, 'Me'), status: 201),
      });
      await _open(tester, backend);
      await openDialog(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'إرسال'));
      await pumpFrames(tester);

      expect(backend.lastBodyOf('POST /services/100/reviews'), {'rating': 5});
    });

    testWidgets('cancel sends nothing', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await openDialog(tester);

      await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /services/100/reviews'), 0);
      expect(find.byType(AlertDialog), findsNothing);
    });

    group('the comment controller lives and dies with the dialog', () {
      TextEditingController commentController(WidgetTester tester) =>
          tester.widget<TextField>(_inDialog(find.byType(TextField))).controller!;

      /// A disposed controller refuses new listeners (in debug builds).
      void expectDisposed(TextEditingController controller) =>
          expect(() => controller.addListener(() {}), throwsFlutterError);

      for (final (how, close) in <(String, Future<void> Function(WidgetTester))>[
        ('cancelled', (t) => t.tap(find.widgetWithText(TextButton, 'إلغاء'))),
        ('submitted', (t) => t.tap(find.widgetWithText(ElevatedButton, 'إرسال'))),
        ('dismissed by tapping outside', (t) => t.tapAt(const Offset(5, 5))),
      ]) {
        testWidgets('disposed once the dialog is $how', (tester) async {
          final backend = _backend(extra: {
            'POST /services/100/reviews': Reply(_review(7, 5, 'Good', 'Me'), status: 201),
          });
          await _open(tester, backend);
          await openDialog(tester);
          await tester.enterText(_inDialog(find.byType(TextField)), 'Good');
          final controller = commentController(tester);

          await close(tester);
          // Still closing: the field is on screen and its controller in use.
          await tester.pump(const Duration(milliseconds: 30));
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(controller.text, 'Good');
          expect(tester.takeException(), isNull);

          await pumpFrames(tester, frames: 12);
          expect(find.byType(AlertDialog), findsNothing);
          expectDisposed(controller);
          expect(tester.takeException(), isNull); // never used after disposal
        });
      }

      testWidgets('tapping outside the dialog sends nothing', (tester) async {
        final backend = _backend();
        await _open(tester, backend);
        await openDialog(tester);
        await tester.enterText(_inDialog(find.byType(TextField)), 'Never sent');

        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(backend.callsTo('POST /services/100/reviews'), 0);
      });

      testWidgets('every opening starts fresh: 5 stars and an empty comment', (tester) async {
        final backend = _backend(extra: {
          'POST /services/100/reviews': Reply(_review(7, 5, null, 'Me'), status: 201),
        });
        await _open(tester, backend);

        await openDialog(tester);
        await tester.tap(_inDialog(find.byType(IconButton)).at(0)); // 1 star
        await tester.enterText(_inDialog(find.byType(TextField)), 'Abandoned');
        final first = commentController(tester);
        await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
        await tester.pumpAndSettle();

        await openDialog(tester);
        expect(commentController(tester), isNot(same(first)));
        expect(commentController(tester).text, isEmpty);
        expect(_inDialog(find.byIcon(Icons.star)), findsNWidgets(5));

        await tester.tap(find.widgetWithText(ElevatedButton, 'إرسال'));
        await pumpFrames(tester);
        expect(backend.lastBodyOf('POST /services/100/reviews'), {'rating': 5});
      });

      testWidgets('the chosen stars are highlighted while the dialog is open', (tester) async {
        await _open(tester, _backend());
        await openDialog(tester);

        await tester.tap(_inDialog(find.byType(IconButton)).at(1)); // 2 stars
        await tester.pump();

        expect(_inDialog(find.byIcon(Icons.star)), findsNWidgets(2));
        expect(_inDialog(find.byIcon(Icons.star_border)), findsNWidgets(3));
      });
    });

    testWidgets('shows the backend reason when reviewing is not allowed',
        (tester) async {
      final backend = _backend(extra: {
        'POST /services/100/reviews': const Reply(
          {'detail': 'You can only review services you have booked'},
          status: 403,
        ),
      });
      await _open(tester, backend);
      await openDialog(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'إرسال'));
      await pumpFrames(tester);

      expect(find.text('You can only review services you have booked'), findsOneWidget);
      expect(backend.callsTo('GET /services/100/reviews'), 1); // no reload on failure
    });
  });
}
