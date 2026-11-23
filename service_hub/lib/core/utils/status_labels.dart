/// Arabic DISPLAY labels for the backend's internal values.
///
/// The backend, the database and the app's own logic keep using the English
/// identifiers ('open', 'pending', ...): comparisons such as
/// `status == 'pending'` and every API call stay exactly as they are. Only
/// what is shown to the user goes through these functions — never compare
/// against a label.
///
/// Values the app doesn't know (e.g. a status added on the server later)
/// never crash and are never shown in English: they read [unknownLabel].
library;

/// Shown for a value the app has no Arabic label for.
const String unknownLabel = 'غير معروف';

String _label(Map<String, String> labels, String? value) =>
    labels[(value ?? '').trim().toLowerCase()] ?? unknownLabel;

// ------------------------------------------------------------- appointments
// backend: AppointmentStatus (app/models/appointment.py)
const Map<String, String> appointmentStatusLabels = {
  'pending': 'بانتظار الموافقة',
  'confirmed': 'مؤكد',
  'rejected': 'مرفوض',
  'completed': 'مكتمل',
  'cancelled': 'ملغى',
  'canceled': 'ملغى',
};

String appointmentStatusLabel(String? status) =>
    _label(appointmentStatusLabels, status);

// ------------------------------------------------------- exchange requests
// backend: ExchangeRequestStatus (app/models/exchange.py)
const Map<String, String> exchangeRequestStatusLabels = {
  'open': 'مفتوح',
  'matched': 'محجوز',
  'closed': 'مغلق',
};

String exchangeRequestStatusLabel(String? status) =>
    _label(exchangeRequestStatusLabels, status);

// ------------------------------------------------------ exchange proposals
// backend: ExchangeProposalStatus (app/models/exchange.py)
const Map<String, String> exchangeProposalStatusLabels = {
  'pending': 'قيد الانتظار',
  'accepted': 'مقبول',
  'rejected': 'مرفوض',
  'withdrawn': 'مسحوب',
};

String exchangeProposalStatusLabel(String? status) =>
    _label(exchangeProposalStatusLabels, status);

// ------------------------------------------------------------------ services
// backend: ServiceStatus (app/models/service.py)
const Map<String, String> serviceStatusLabels = {
  'active': 'نشطة',
  'inactive': 'متوقفة',
  'suspended': 'موقوفة',
};

String serviceStatusLabel(String? status) => _label(serviceStatusLabels, status);

// --------------------------------------------------------------- user roles
// backend: UserRole (app/models/user.py)
const Map<String, String> userRoleLabels = {
  'admin': 'مشرف',
  'user': 'مستخدم',
};

String userRoleLabel(String? role) => _label(userRoleLabels, role);

// --------------------------------------------------------------- price units
// backend: Service.price_unit — a display hint ('fixed', 'per_hour',
// 'per_visit', ...). The app itself always publishes 'fixed'.
const Map<String, String> priceUnitLabels = {
  'fixed': 'سعر ثابت',
  'per_hour': 'بالساعة',
  'hourly': 'بالساعة',
  'hour': 'بالساعة',
  'per_day': 'باليوم',
  'daily': 'باليوم',
  'day': 'باليوم',
  'per_visit': 'بالزيارة',
  'visit': 'بالزيارة',
};

/// The Arabic price unit, or null when the unit is unknown — the caller
/// then simply shows the price without a unit rather than an English word.
String? priceUnitLabel(String? unit) =>
    priceUnitLabels[(unit ?? '').trim().toLowerCase()];
