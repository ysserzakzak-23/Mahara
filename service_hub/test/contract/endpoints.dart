import 'package:service_hub/features/admin/data/admin_models.dart';
import 'package:service_hub/features/auth/data/auth_models.dart';
import 'package:service_hub/features/availability/data/availability_models.dart';
import 'package:service_hub/features/booking/data/appointment_models.dart';
import 'package:service_hub/features/exchange/data/exchange_models.dart';
import 'package:service_hub/features/notifications/data/notification_models.dart';
import 'package:service_hub/features/reviews/data/review_models.dart';
import 'package:service_hub/features/service/data/service_models.dart';

const apiPrefix = '/api/v1';

/// One endpoint the app calls: HTTP method, path template (`{}` = an id) and the
/// code that parses its response (null = the app ignores the body).
///
/// KEEP THIS LIST IN SYNC with the `*_service.dart` files: when the app starts
/// calling a new endpoint, add a line here and the contract tests cover it.
class Endpoint {
  const Endpoint(this.method, this.path, [this.parse]);

  final String method;
  final String path;
  final Object? Function(dynamic json)? parse;
}

Map<String, dynamic> _obj(dynamic j) => j as Map<String, dynamic>;

List<T> _list<T>(dynamic j, T Function(Map<String, dynamic>) build) =>
    (j as List).map((e) => build(e as Map<String, dynamic>)).toList();

final appEndpoints = <Endpoint>[
  // auth & profile
  Endpoint('POST', '/auth/register', (j) => AppUser.fromJson(_obj(j))),
  Endpoint('POST', '/auth/login', (j) => AuthTokens.fromJson(_obj(j))),
  Endpoint('POST', '/auth/forgot-password'),
  Endpoint('POST', '/auth/reset-password'),
  Endpoint('GET', '/users/me', (j) => AppUser.fromJson(_obj(j))),
  Endpoint('PATCH', '/users/me', (j) => AppUser.fromJson(_obj(j))),
  Endpoint('GET', '/users/{}', (j) => ServiceProvider.fromJson(_obj(j))),
  Endpoint('GET', '/cities', (j) => (j as List).map((e) => e as String).toList()),
  Endpoint('POST', '/uploads/image', (j) => _obj(j)['url'] as String),

  // catalog & search
  Endpoint('GET', '/categories', (j) => _list(j, ServiceCategory.fromJson)),
  Endpoint('GET', '/services', (j) => _list(j, ServiceListItem.fromJson)),
  Endpoint('GET', '/services/{}', (j) => ServiceDetail.fromJson(_obj(j))),
  Endpoint('GET', '/services/provider/{}', (j) => _list(j, ServiceListItem.fromJson)),
  Endpoint('POST', '/services', (j) => ServiceDetail.fromJson(_obj(j))),
  Endpoint('PATCH', '/services/{}', (j) => ServiceDetail.fromJson(_obj(j))),
  Endpoint('DELETE', '/services/{}'),
  Endpoint('GET', '/search/services', (j) => _list(j, ServiceListItem.fromJson)),
  Endpoint('GET', '/search/semantic', (j) => _list(j, ServiceListItem.fromJson)),
  Endpoint('GET', '/search/smart', (j) => _list(j, ServiceListItem.fromJson)),

  // portfolio & reviews
  Endpoint('GET', '/services/{}/portfolio', (j) => _list(j, PortfolioItem.fromJson)),
  Endpoint('POST', '/services/{}/portfolio', (j) => PortfolioItem.fromJson(_obj(j))),
  Endpoint('DELETE', '/services/{}/portfolio/{}'),
  Endpoint('GET', '/services/{}/reviews', (j) => _list(j, Review.fromJson)),
  Endpoint('GET', '/services/{}/reviews/summary', (j) => RatingSummary.fromJson(_obj(j))),
  Endpoint('POST', '/services/{}/reviews', (j) => Review.fromJson(_obj(j))),

  // availability & appointments
  Endpoint('GET', '/providers/{}/availability', (j) => _list(j, AvailabilityWindow.fromJson)),
  Endpoint('GET', '/providers/{}/availability/slots', (j) => DaySlots.fromJson(_obj(j))),
  Endpoint('POST', '/providers/{}/availability', (j) => AvailabilityWindow.fromJson(_obj(j))),
  Endpoint('DELETE', '/providers/{}/availability/{}'),
  Endpoint('GET', '/appointments/me', (j) => _list(j, Appointment.fromJson)),
  Endpoint('POST', '/appointments', (j) => Appointment.fromJson(_obj(j))),
  Endpoint('POST', '/appointments/{}/accept', (j) => Appointment.fromJson(_obj(j))),
  Endpoint('POST', '/appointments/{}/reject', (j) => Appointment.fromJson(_obj(j))),
  Endpoint('POST', '/appointments/{}/cancel', (j) => Appointment.fromJson(_obj(j))),
  Endpoint('POST', '/appointments/{}/complete', (j) => Appointment.fromJson(_obj(j))),

  // exchange
  Endpoint('POST', '/exchange-requests', (j) => ExchangeRequestModel.fromJson(_obj(j))),
  Endpoint('GET', '/exchange-requests', (j) => _list(j, ExchangeRequestModel.fromJson)),
  Endpoint('GET', '/exchange-requests/me', (j) => _list(j, ExchangeRequestModel.fromJson)),
  Endpoint('GET', '/exchange-requests/search', (j) => _list(j, ExchangeRequestModel.fromRankedJson)),
  Endpoint('GET', '/exchange-requests/interests', (j) => _list(j, ExchangeRequestModel.fromRankedJson)),
  Endpoint('GET', '/exchange-requests/{}/matches', (j) => _list(j, DirectMatch.fromJson)),
  Endpoint('DELETE', '/exchange-requests/{}'),
  Endpoint('POST', '/exchange-requests/{}/proposals', (j) => ExchangeProposalModel.fromJson(_obj(j))),
  Endpoint('GET', '/exchange-requests/{}/proposals', (j) => _list(j, ExchangeProposalModel.fromJson)),
  Endpoint('GET', '/exchange-proposals/me', (j) => _list(j, ExchangeProposalModel.fromJson)),
  Endpoint('POST', '/exchange-proposals/{}/accept', (j) => ExchangeProposalModel.fromJson(_obj(j))),
  Endpoint('POST', '/exchange-proposals/{}/reject', (j) => ExchangeProposalModel.fromJson(_obj(j))),

  // notifications (the app ignores the bodies of the POSTs)
  Endpoint('GET', '/notifications', (j) => _list(j, AppNotification.fromJson)),
  Endpoint('GET', '/notifications/unread-count', (j) => _obj(j)['unread_count'] as int),
  Endpoint('POST', '/notifications/{}/read'),
  Endpoint('POST', '/notifications/read-all'),
  Endpoint('POST', '/notifications/devices'),

  // admin
  Endpoint('GET', '/admin/stats', (j) => PlatformStats.fromJson(_obj(j))),
  Endpoint('GET', '/admin/users', (j) => _list(j, AdminUser.fromJson)),
  Endpoint('PUT', '/admin/users/{}/active-status', (j) => AdminUser.fromJson(_obj(j))),
  Endpoint('PUT', '/admin/users/{}/role', (j) => AdminUser.fromJson(_obj(j))),
  Endpoint('GET', '/admin/services', (j) => _list(j, AdminServiceListing.fromJson)),
  Endpoint('PUT', '/admin/services/{}/status', (j) => AdminServiceListing.fromJson(_obj(j))),
];

/// Fields some Dart models read only on SOME endpoints (search results add a
/// distance or a similarity score; list endpoints do not). Reading them where
/// the backend does not send them is expected, so they are not reported.
const optionalEnrichmentKeys = {
  'distance_km',
  'similarity_score',
  'average_rating',
  'total_reviews',
};

/// String values the app compares against, per backend enum. If the backend
/// renames or drops one, the UI silently stops recognising it.
const enumExpectations = <String, List<String>>{
  'AppointmentStatus': ['pending', 'confirmed', 'rejected', 'cancelled', 'completed'],
  'ExchangeRequestStatus': ['open', 'matched', 'closed'],
  'ExchangeProposalStatus': ['pending', 'accepted', 'rejected'],
  'ServiceStatus': ['active', 'inactive', 'suspended'],
  'UserRole': ['user', 'admin'],
  'NotificationType': ['new_review', 'barter_match'],
};

/// The notification screen picks an icon by prefix.
const notificationTypePrefixes = ['appointment', 'exchange'];
