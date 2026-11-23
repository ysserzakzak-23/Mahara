import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/features/admin/admin_dashboard_screen.dart';
import 'package:service_hub/features/admin/data/admin_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _stats = {
  'total_users': 120,
  'total_providers': 30,
  'active_services': 55,
  'total_appointments': 400,
  'completed_appointments': 250,
  'total_reviews': 99,
  'average_platform_rating': 4.5,
};

Map<String, dynamic> _user(int id, {String role = 'user', bool active = true, bool provider = false, String? name}) => {
      'id': id,
      'email': 'user$id@example.com',
      'role': role,
      'is_provider': provider,
      'is_active': active,
      'profile': name == null ? null : {'full_name': name},
    };

Map<String, dynamic> _listing(int id, {String status = 'active', double? price = 25.5}) => {
      'id': id,
      'title': 'Listing $id',
      'price': price?.toString(),
      'status': status,
      'provider_id': 3,
      'category_id': 1,
    };

RoutedBackend _backend({
  List<Map<String, dynamic>>? users,
  List<Map<String, dynamic>>? services,
  Map<String, Reply> extra = const {},
}) =>
    RoutedBackend({
      'GET /admin/stats': const Reply(_stats),
      'GET /admin/users': Reply(users ?? [_user(5, name: 'Sara Hassan', provider: true)]),
      'GET /admin/services': Reply(services ?? [_listing(1)]),
      ...extra,
    });

Future<void> _open(WidgetTester tester, RoutedBackend backend) async {
  useTallScreen(tester);
  await tester.pumpWidget(MaterialApp(
    home: AdminDashboardScreen(adminService: AdminService(apiClient: apiFor(backend))),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  testWidgets('has three tabs and starts on Stats', (tester) async {
    await _open(tester, _backend());

    expect(find.text('لوحة الإدارة'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'الإحصائيات'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'المستخدمون'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'الخدمات'), findsOneWidget);
    expect(find.text('إجمالي المستخدمين'), findsOneWidget);
  });

  group('الإحصائيات', () {
    testWidgets('shows every counter', (tester) async {
      await _open(tester, _backend());

      for (final label in [
        'إجمالي المستخدمين', 'مزوّدو الخدمة', 'الخدمات النشطة', 'المواعيد',
        'المواعيد المكتملة', 'التقييمات', 'متوسط التقييم',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('120'), findsOneWidget);
      expect(find.text('250'), findsOneWidget);
      expect(find.text('4.50'), findsOneWidget);
    });

    testWidgets('shows the error when stats fail (e.g. not an admin)', (tester) async {
      await _open(
        tester,
        _backend(extra: {
          'GET /admin/stats': const Reply({'detail': 'Admin access required'}, status: 403),
        }),
      );
      expect(find.text('Admin access required'), findsOneWidget);
    });
  });

  group('المستخدمون', () {
    testWidgets('lists users with role and provider flag', (tester) async {
      await _open(
        tester,
        _backend(users: [
          _user(5, name: 'Sara Hassan', provider: true),
          _user(6, role: 'admin'),
        ]),
      );
      await _tab(tester, 'المستخدمون');

      expect(find.text('Sara Hassan'), findsOneWidget);
      expect(find.text('user5@example.com · مستخدم · مزوّد خدمة'), findsOneWidget);
      expect(find.text('user6@example.com'), findsOneWidget); // no name -> email as title
      expect(find.text('user6@example.com · مشرف'), findsOneWidget);
    });

    testWidgets('promoting a user sends role=admin and reloads', (tester) async {
      final backend = _backend(extra: {
        'PUT /admin/users/5/role': Reply(_user(5, role: 'admin')),
      });
      await _open(tester, backend);
      await _tab(tester, 'المستخدمون');

      await tester.tap(find.byTooltip('منح صلاحية المشرف'));
      await tester.pumpAndSettle();

      expect(backend.lastBodyOf('PUT /admin/users/5/role'), {'role': 'admin'});
      expect(backend.callsTo('GET /admin/users'), 2);
    });

    testWidgets('an admin row offers "إزالة صلاحية المشرف" which sends role=user', (tester) async {
      final backend = _backend(users: [_user(6, role: 'admin')], extra: {
        'PUT /admin/users/6/role': Reply(_user(6)),
      });
      await _open(tester, backend);
      await _tab(tester, 'المستخدمون');

      await tester.tap(find.byTooltip('إزالة صلاحية المشرف'));
      await tester.pumpAndSettle();

      expect(backend.lastBodyOf('PUT /admin/users/6/role'), {'role': 'user'});
    });

    testWidgets('the switch deactivates an active user', (tester) async {
      final backend = _backend(extra: {
        'PUT /admin/users/5/active-status': Reply(_user(5, active: false)),
      });
      await _open(tester, backend);
      await _tab(tester, 'المستخدمون');
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(backend.lastBodyOf('PUT /admin/users/5/active-status'), {'is_active': false});
    });

    testWidgets('backend refusals are shown (e.g. deactivating yourself)', (tester) async {
      final backend = _backend(extra: {
        'PUT /admin/users/5/active-status': const Reply(
          {'detail': 'You cannot deactivate your own admin account'},
          status: 422,
        ),
      });
      await _open(tester, backend);
      await _tab(tester, 'المستخدمون');

      await tester.tap(find.byType(Switch));
      await pumpFrames(tester);

      expect(find.text('You cannot deactivate your own admin account'), findsOneWidget);
    });
  });

  group('الخدمات', () {
    testWidgets('lists listings with price, status and provider', (tester) async {
      await _open(tester, _backend());
      await _tab(tester, 'الخدمات');

      expect(find.text('Listing 1'), findsOneWidget);
      expect(find.text('25.50 \$ · نشطة · مزوّد #3'), findsOneWidget);
      expect(find.text('إيقاف'), findsOneWidget);
    });

    testWidgets('a listing without a price says so instead of showing 0', (tester) async {
      await _open(tester, _backend(services: [_listing(1, price: null)]));
      await _tab(tester, 'الخدمات');

      expect(find.text('السعر غير محدد · نشطة · مزوّد #3'), findsOneWidget);
    });

    testWidgets('suspending sends status=suspended and reloads', (tester) async {
      final backend = _backend(extra: {
        'PUT /admin/services/1/status': Reply(_listing(1, status: 'suspended')),
      });
      await _open(tester, backend);
      await _tab(tester, 'الخدمات');

      await tester.tap(find.text('إيقاف'));
      await tester.pumpAndSettle();

      expect(backend.lastBodyOf('PUT /admin/services/1/status'), {'status': 'suspended'});
      expect(backend.callsTo('GET /admin/services'), 2);
    });

    testWidgets('a suspended listing offers Reinstate -> status=active', (tester) async {
      final backend = _backend(services: [_listing(1, status: 'suspended')], extra: {
        'PUT /admin/services/1/status': Reply(_listing(1)),
      });
      await _open(tester, backend);
      await _tab(tester, 'الخدمات');

      await tester.tap(find.text('إعادة تفعيل'));
      await tester.pumpAndSettle();

      expect(backend.lastBodyOf('PUT /admin/services/1/status'), {'status': 'active'});
    });
  });

  group('Arabic labels', () {
    testWidgets('each service status has its own Arabic label (inactive is not «نشطة»)',
        (tester) async {
      await _open(tester, _backend(services: [
        _listing(1, status: 'active'),
        _listing(2, status: 'inactive'),
        _listing(3, status: 'suspended'),
      ]));
      await _tab(tester, 'الخدمات');

      expect(find.text('25.50 \$ · نشطة · مزوّد #3'), findsOneWidget);
      expect(find.text('25.50 \$ · متوقفة · مزوّد #3'), findsOneWidget);
      expect(find.text('25.50 \$ · موقوفة · مزوّد #3'), findsOneWidget);
    });

    testWidgets('user roles are shown in Arabic', (tester) async {
      await _open(tester, _backend(users: [
        _user(1, role: 'admin', name: 'Admin One'),
        _user(2, role: 'user', name: 'User Two'),
      ]));
      await _tab(tester, 'المستخدمون');

      expect(find.text('user1@example.com · مشرف'), findsOneWidget);
      expect(find.text('user2@example.com · مستخدم'), findsOneWidget);
      expect(find.textContaining('admin'), findsNothing);
    });
  });
}
