import 'package:flutter/material.dart';

import '../../core/config/api_config.dart';
import '../../core/api/api_exception.dart';
import '../../core/utils/date_labels.dart';
import '../../core/utils/status_labels.dart';
import '../profile/provider_profile_screen.dart';
import '../service/data/service_models.dart';
import 'data/appointment_models.dart';
import 'data/appointment_service.dart';
import '../../core/utils/image_sizing.dart';

/// Everything about one booking: when, the notes, who is on the other side
/// (tap the name to open their profile) and the actions that make sense for
/// the viewer — accept / reject, complete, cancel.
///
/// [asProvider] is true when it is opened from "جدول مواعيدي" (the other
/// party is the customer) and false from "حجوزاتي" (the other party is the
/// service provider).
///
/// Pops with `true` when something changed, so the list can refresh.
class AppointmentDetailsScreen extends StatefulWidget {
  const AppointmentDetailsScreen({
    super.key,
    required this.appointment,
    required this.asProvider,
    this.appointmentService,
    this.profileBuilder,
  });

  final Appointment appointment;
  final bool asProvider;

  /// Optional overrides, mainly so widget tests can inject a fake backend.
  final AppointmentService? appointmentService;
  final Widget Function(int userId, String title)? profileBuilder;

  @override
  State<AppointmentDetailsScreen> createState() => _AppointmentDetailsScreenState();
}

class _AppointmentDetailsScreenState extends State<AppointmentDetailsScreen> {
  late final AppointmentService _appointments =
      widget.appointmentService ?? AppointmentService();
  late Appointment _a = widget.appointment;
  bool _changed = false;
  bool _busy = false;

  String get _status => _a.status.toLowerCase();

  ServiceProvider get _other => widget.asProvider ? _a.customer : _a.provider;

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool> _confirm(String title, String body, String yes) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('رجوع'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(yes),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _run(Future<Appointment> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      final updated = await action();
      if (!mounted) return;
      setState(() {
        _a = updated;
        _changed = true;
      });
      _showMessage(done);
    } on ApiException catch (e) {
      if (mounted) _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() => _run(() => _appointments.accept(_a.id), 'تم قبول الحجز.');

  Future<void> _reject() async {
    final ok = await _confirm(
      'رفض طلب الحجز هذا؟',
      'سيتم إشعار العميل، وسيصبح هذا الوقت متاحاً ليحجزه شخص آخر.',
      'رفض',
    );
    if (ok) await _run(() => _appointments.reject(_a.id), 'تم رفض الحجز.');
  }

  Future<void> _cancel() async {
    final ok = await _confirm(
      'إلغاء هذا الموعد؟',
      'سيصبح هذا الوقت متاحاً ليحجزه شخص آخر.',
      'إلغاء الموعد',
    );
    if (ok) await _run(() => _appointments.cancel(_a.id), 'تم إلغاء الموعد.');
  }

  Future<void> _complete() =>
      _run(() => _appointments.complete(_a.id), 'تم تحديد الموعد كمكتمل.');

  void _openProfile() {
    final title = widget.asProvider ? 'ملف العميل' : 'ملف المزوّد';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            widget.profileBuilder?.call(_other.id, title) ??
            ProviderProfileScreen(providerId: _other.id, title: title),
      ),
    );
  }

  Color _statusColor() {
    switch (_status) {
      case 'pending':
        return Colors.orange.shade800;
      case 'confirmed':
        return Colors.green.shade700;
      case 'completed':
        return Colors.blue.shade700;
      default:
        return Colors.red.shade700;
    }
  }

  IconData _statusIcon() {
    switch (_status) {
      case 'pending':
        return Icons.hourglass_top;
      case 'confirmed':
        return Icons.check_circle;
      case 'completed':
        return Icons.task_alt;
      default:
        return Icons.cancel;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تفاصيل الموعد'),
          titleSpacing: -2,
          backgroundColor: const Color.fromARGB(0, 77, 75, 75),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _statusBanner(),
            const SizedBox(height: 16),
            _infoCard(),
            const SizedBox(height: 16),
            _personCard(),
            const SizedBox(height: 16),
            _notesCard(),
            ..._actions(),
          ],
        ),
      ),
    );
  }

  Widget _statusBanner() {
    final color = _statusColor();
    return Container(
      key: const Key('status-banner'),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(_statusIcon(), color: color),
          const SizedBox(width: 10),
          Text(
            appointmentStatusLabel(_a.status),
            style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: Colors.grey),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 2),
                  Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _infoCard() => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              _row(Icons.handyman_outlined, 'الخدمة', _a.serviceTitle),
              if (_a.hasTime) ...[
                _row(Icons.calendar_month, 'اليوم والتاريخ', formatLongDate(_a.startTime!)),
                _row(
                  Icons.access_time,
                  'الوقت',
                  'من ${formatHm(_a.startTime!)} إلى ${formatHm(_a.endTime!)}',
                ),
              ] else
                _row(
                  Icons.event_note,
                  'الموعد',
                  'لم يُحدد يوم أو ساعة، الخدمة عن بعد، تواصلا مع بعضكما للاتفاق على الموعد.',
                ),
            ],
          ),
        ),
      );

  Widget _personCard() {
    final person = _other;
    return Card(
      child: ListTile(
        key: const Key('open-profile'),
        onTap: _openProfile,
        leading: CircleAvatar(
          backgroundColor: Colors.grey.shade300,
          backgroundImage: person.avatarUrl != null
              ? sizedNetworkImage(
                  context,
                  ApiConfig.resolveUrl(person.avatarUrl!),
                  longestSide: 40,    // default CircleAvatar
                )
              : null,
          child: person.avatarUrl == null ? const Icon(Icons.person) : null,
        ),
        title: Text(
          person.displayName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          widget.asProvider ? 'العميل · عرض الملف الشخصي' : 'صاحب الخدمة · عرض الملف الشخصي',
        ),
        trailing: const Icon(Icons.chevron_left),
      ),
    );
  }

  Widget _notesCard() {
    final notes = _a.customerNotes?.trim() ?? '';
    final reason = _a.cancellationReason?.trim() ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            _row(
              Icons.notes,
              widget.asProvider ? 'ملاحظات العميل' : 'ملاحظاتك',
              notes.isEmpty ? 'لا توجد ملاحظات.' : notes,
            ),
            if (reason.isNotEmpty) _row(Icons.info_outline, 'سبب الإلغاء', reason),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions() {
    final pending = _status == 'pending';
    final confirmed = _status == 'confirmed';
    final buttons = <Widget>[];

    if (widget.asProvider && pending) {
      buttons.add(_button('قبول', Icons.check_circle_outline, Colors.green, _accept));
      buttons.add(_button('رفض', Icons.cancel_outlined, Colors.red, _reject));
    }
    if (widget.asProvider && confirmed) {
      buttons.add(_button('تحديد كمكتمل', Icons.task_alt, Colors.blue, _complete));
    }
    if ((pending || confirmed) && !(widget.asProvider && pending)) {
      buttons.add(_button('إلغاء الموعد', Icons.event_busy, Colors.red, _cancel));
    }
    if (!widget.asProvider && pending) {
      buttons.insert(
        0,
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'بانتظار موافقة صاحب الخدمة على طلبك.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    if (buttons.isEmpty) return const [];
    return [const SizedBox(height: 24), ...buttons];
  }

  Widget _button(String label, IconData icon, Color color, VoidCallback onPressed) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: OutlinedButton.icon(
          onPressed: _busy ? null : onPressed,
          icon: Icon(icon, color: color),
          label: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            side: BorderSide(color: color),
          ),
        ),
      );
}
