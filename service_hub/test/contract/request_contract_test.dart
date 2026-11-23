import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/config/api_config.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/admin/data/admin_service.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/availability/data/availability_service.dart';
import 'package:service_hub/features/booking/data/appointment_service.dart';
import 'package:service_hub/features/exchange/data/exchange_service.dart';
import 'package:service_hub/features/notifications/data/notification_service.dart';
import 'package:service_hub/features/reviews/data/review_service.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:service_hub/features/service/data/portfolio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import 'contract_support.dart';

/// App -> backend: do the requests the app really sends fit what the backend accepts?
///
/// Each case calls a real service method, captures the HTTP request it produces
/// and checks URL, query string and JSON body against the backend's schemas.
final _calls = <String, Future<void> Function(ApiClient api)>{
  // ---- auth & profile
  'register (with phone)': (api) => AuthService(apiClient: api, tokenStore: TokenStore())
      .register(email: 'a@b.com', password: 'Secret123!', fullName: 'Ahmad Ali', city: 'دمشق', phoneNumber: '0912345678'),
  'register (without phone)': (api) => AuthService(apiClient: api, tokenStore: TokenStore())
      .register(email: 'a@b.com', password: 'Secret123!', fullName: 'Ahmad Ali', city: 'دمشق'),
  'login': (api) => AuthService(apiClient: api, tokenStore: TokenStore()).login(email: 'a@b.com', password: 'Secret123!'),
  'update profile (every field)': (api) => AuthService(apiClient: api, tokenStore: TokenStore()).updateProfile(
      fullName: 'Ahmad Ali', phoneNumber: '0912345678', bio: 'bio', avatarUrl: '/uploads/a.png', city: 'دمشق'),
  'update profile (remove photo)': (api) =>
      AuthService(apiClient: api, tokenStore: TokenStore()).updateProfile(clearAvatar: true),

  // ---- catalog & search
  'list services (filters)': (api) => CatalogService(apiClient: api).services(categoryId: 1, city: 'دمشق'),
  'list services (no filters)': (api) => CatalogService(apiClient: api).services(),
  'nearby search': (api) =>
      CatalogService(apiClient: api).searchNearby(latitude: 33.5, longitude: 36.3, radiusKm: 10, categoryId: 2),
  'semantic search': (api) => CatalogService(apiClient: api).searchSemantic(query: 'تكييف', categoryId: 2),
  'smart search': (api) =>
      CatalogService(apiClient: api).searchSmart(query: 'بدي أصلح حنفية', categoryId: 2, city: 'دمشق'),
  'create service (every field)': (api) => CatalogService(apiClient: api).createService(
        categoryId: 1, description: 'I fix all kinds of pipes', price: 25.5,
        priceUnit: 'hour', coverImageUrl: '/uploads/c.png', isRemote: true,
        latitude: 33.5, longitude: 36.3, customCategoryLabel: 'سباك',
      ),
  'create service (required fields only)': (api) => CatalogService(apiClient: api)
      .createService(categoryId: 1, description: 'I fix all kinds of pipes'),
  'create service (with a price)': (api) => CatalogService(apiClient: api)
      .createService(categoryId: 1, description: 'I fix all kinds of pipes', price: 25.5),
  'update service (remove the price)': (api) =>
      CatalogService(apiClient: api).updateService(100, removePrice: true),
  'update service (every field)': (api) => CatalogService(apiClient: api).updateService(
        100, categoryId: 1, title: 'New title', description: 'A new description', price: 30,
        priceUnit: 'fixed', status: 'inactive', latitude: 33.5, longitude: 36.3,
        coverImageUrl: '/uploads/c.png', isRemote: false, customCategoryLabel: 'سباك',
      ),
  'delete service': (api) => CatalogService(apiClient: api).deleteService(100),

  // ---- portfolio, reviews, availability
  'add portfolio photo (with caption)': (api) => PortfolioService(apiClient: api).add(100, '/uploads/p.png', caption: 'After'),
  'add portfolio photo': (api) => PortfolioService(apiClient: api).add(100, '/uploads/p.png'),
  'review (with comment)': (api) => ReviewService(apiClient: api).submitReview(100, rating: 4, comment: 'Great'),
  'review (stars only)': (api) => ReviewService(apiClient: api).submitReview(100, rating: 5),
  'add availability window': (api) =>
      AvailabilityService(apiClient: api).create(2, dayOfWeek: 0, startTime: '09:00', endTime: '17:30'),
  'remove availability window': (api) => AvailabilityService(apiClient: api).deactivate(2, 9),
  'day slots': (api) => AvailabilityService(apiClient: api).slots(2, DateTime(2026, 10, 5)),
  'book without day/hour': (api) => AppointmentService(apiClient: api).createAppointment(serviceId: 1, customerNotes: 'x'),

  // ---- appointments
  'my appointments (customer)': (api) => AppointmentService(apiClient: api).myAppointments(),
  'my appointments (provider)': (api) => AppointmentService(apiClient: api).myAppointments(asProvider: true),
  'book an appointment': (api) => AppointmentService(apiClient: api).createAppointment(
        serviceId: 100, startTime: DateTime.utc(2026, 10, 5, 10), endTime: DateTime.utc(2026, 10, 5, 11)),
  'book an appointment (with notes)': (api) => AppointmentService(apiClient: api).createAppointment(
        serviceId: 100, startTime: DateTime.utc(2026, 10, 5, 10), endTime: DateTime.utc(2026, 10, 5, 11),
        customerNotes: 'bring tools'),
  'accept appointment': (api) => AppointmentService(apiClient: api).accept(5),
  'reject appointment (reason)': (api) => AppointmentService(apiClient: api).reject(5, reason: 'full'),
  'reject appointment': (api) => AppointmentService(apiClient: api).reject(5),
  'cancel appointment (reason)': (api) => AppointmentService(apiClient: api).cancel(5, reason: 'busy'),
  'cancel appointment': (api) => AppointmentService(apiClient: api).cancel(5),
  'complete appointment': (api) => AppointmentService(apiClient: api).complete(5),

  // ---- exchange
  'open an exchange request': (api) =>
      ExchangeService(apiClient: api).createRequest(offeredServiceId: 1, wantedCategoryId: 2),
  'open an exchange request (custom wish)': (api) => ExchangeService(apiClient: api)
      .createRequest(offeredServiceId: 1, wantedCategoryId: 9, wantedCustomCategoryLabel: 'نجار'),
  'propose an exchange': (api) =>
      ExchangeService(apiClient: api).createProposal(requestId: 7, proposedServiceId: 55),
  'propose an exchange (with message)': (api) =>
      ExchangeService(apiClient: api).createProposal(requestId: 7, proposedServiceId: 55, message: 'deal?'),
  'proposals of one request': (api) =>
      ExchangeService(apiClient: api).proposalsForRequest(7),
  'received proposals': (api) => ExchangeService(apiClient: api).listMyProposals(sent: false),
  'sent proposals': (api) => ExchangeService(apiClient: api).listMyProposals(sent: true),
  'accept proposal': (api) => ExchangeService(apiClient: api).acceptProposal(3),
  'reject proposal': (api) => ExchangeService(apiClient: api).rejectProposal(3),
  'matches of a request': (api) => ExchangeService(apiClient: api).matchesForRequest(7),
  'search exchange requests': (api) => ExchangeService(apiClient: api).searchRequests('تصليح مكيف'),
  'my interests': (api) => ExchangeService(apiClient: api).listInterests(),
  'search my interests': (api) => ExchangeService(apiClient: api).listInterests(query: 'برمجة'),
  'close an exchange request': (api) => ExchangeService(apiClient: api).closeRequest(7),

  // ---- notifications
  'notifications': (api) => NotificationService(apiClient: api).list(),
  'unread notifications': (api) => NotificationService(apiClient: api).list(unreadOnly: true),
  'mark all read': (api) => NotificationService(apiClient: api).markAllRead(),
  'register a device': (api) => NotificationService(apiClient: api).registerDevice('a-valid-fcm-token'),
  'register a device (with label)': (api) =>
      NotificationService(apiClient: api).registerDevice('a-valid-fcm-token', deviceLabel: 'Pixel'),

  // ---- admin
  'admin: services (filtered)': (api) => AdminService(apiClient: api).services(status: 'suspended'),
  'admin: deactivate a user': (api) => AdminService(apiClient: api).setUserActive(5, false),
  'admin: change a role': (api) => AdminService(apiClient: api).setUserRole(5, 'admin'),
  'admin: suspend a service': (api) => AdminService(apiClient: api).setServiceStatus(1, 'suspended'),
};

Future<http.Request> _capture(Future<void> Function(ApiClient api) call) async {
  final backend = FakeBackend(null); // answers 200 with an empty body
  final api = ApiClient(httpClient: backend.client, tokenStore: TokenStore());
  try {
    await call(api);
  } catch (_) {
    // The response is empty, so parsing may fail - only the request matters here.
  }
  return backend.requests.last;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final contract = ApiContract.load();

  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  group('requests the app sends are accepted by the backend', () {
    _calls.forEach((name, call) {
      test(name, () async {
        final request = await _capture(call);
        final method = request.method;
        final path = request.url.path;
        final label = '$method ${path.replaceFirst(ApiConfig.apiPrefix, '')}';

        final found = contract.operationForRequest(method, path);
        expect(found, isNotNull, reason: 'The backend has no operation for $method $path');
        final operation = found!.operation;
        final problems = <String>[];

        // ---- query string
        final declared = {for (final p in contract.queryParameters(operation)) p['name'] as String: p};
        for (final entry in request.url.queryParameters.entries) {
          final param = declared[entry.key];
          if (param == null) {
            problems.add('query "${entry.key}": the backend does not declare this parameter');
            continue;
          }
          problems.addAll(validateSchema(
            contract,
            coerceQueryValue(entry.value),
            (param['schema'] as Map).cast<String, dynamic>(),
            'query "${entry.key}"',
          ));
        }
        for (final param in declared.values) {
          if (param['required'] == true && !request.url.queryParameters.containsKey(param['name'])) {
            problems.add('query "${param['name']}": required by the backend but not sent');
          }
        }

        // ---- JSON body
        final schema = contract.requestBodySchema(operation);
        if (request.body.isNotEmpty) {
          if (schema == null) {
            problems.add('body: the app sends one but the backend accepts none');
          } else {
            problems.addAll(validateSchema(contract, jsonDecode(request.body), schema, 'body'));
          }
        } else if (contract.requestBodyRequired(operation)) {
          problems.add('body: required by the backend but the app sent none');
        }

        expect(
          problems,
          isEmpty,
          reason: '$label does not match the backend contract (${found.template}):\n  ${problems.join('\n  ')}',
        );
      });
    });
  });
}
