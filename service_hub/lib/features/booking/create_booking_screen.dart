import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../core/utils/date_labels.dart';
import '../availability/data/availability_models.dart';
import '../availability/data/availability_service.dart';
import 'data/appointment_service.dart';
import '../../core/utils/error_text.dart';

class CreateBookingScreen extends StatefulWidget {
  final int serviceId;
  final String serviceTitle;
  final int providerId;

  /// A remote service whose provider set no working hours is booked WITHOUT
  /// a day and hour (the two sides agree on it afterwards).
  final bool isRemote;

  final AppointmentService? appointmentService;
  final AvailabilityService? availabilityService;
  final DateTime Function()? clock;

  const CreateBookingScreen({
    super.key,
    required this.serviceId,
    required this.serviceTitle,
    required this.providerId,
    this.isRemote = false,
    this.appointmentService,
    this.availabilityService,
    this.clock,
  });

  @override
  State<CreateBookingScreen> createState() => _CreateBookingScreenState();
}

class _CreateBookingScreenState extends State<CreateBookingScreen> {
  late final AppointmentService _appointments =
      widget.appointmentService ?? AppointmentService();

  late final AvailabilityService _availabilityService =
      widget.availabilityService ?? AvailabilityService();

  final _notesController = TextEditingController();

  static const _appointmentDuration = Duration(hours: 1);

  static const _hideBookedSlots = false;

  // Sunday first: backend indexes 0=Monday ... 6=Sunday
  static const _displayOrder = [6, 0, 1, 2, 3, 4, 5];

  DateTime _now() => (widget.clock ?? DateTime.now)();

  DateTime? _date;
  DaySlot? _selected;

  bool _loading = false;

  late Future<List<AvailabilityWindow>> _availabilityFuture;
  Future<DaySlots>? _slotsFuture;

  /// The provider's working hours once loaded (null while loading).
  List<AvailabilityWindow>? _windows;

  @override
  void initState() {
    super.initState();
    _availabilityFuture = _availabilityService.list(widget.providerId).then((all) {
      _windows = all;
      return all;
    });
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Set<int> _workingWeekdays(List<AvailabilityWindow> all) => {
    for (final w in all)
      if (w.isActive) w.dayOfWeek,
  };

  /// Remote service + provider without working hours: no day/hour is chosen.
  bool _isRequestWithoutTime(List<AvailabilityWindow> all) =>
      widget.isRemote && _workingWeekdays(all).isEmpty;

  List<AvailabilityWindow> _windowsOn(
    List<AvailabilityWindow> all,
    int weekday,
  ) {
    final list = all.where((w) => w.isActive && w.dayOfWeek == weekday).toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    return list;
  }

  /// The first date from today on that falls on one of [weekdays].
  DateTime? _firstWorkingDate(Set<int> weekdays) {
    final today = _now();

    for (var i = 0; i < 14; i++) {
      final d = DateTime(
        today.year,
        today.month,
        today.day,
      ).add(Duration(days: i));

      if (weekdays.contains(d.weekday - 1)) return d;
    }

    return null;
  }

  Future<void> _pickDate(List<AvailabilityWindow> windows) async {
    final weekdays = _workingWeekdays(windows);
    final first = _firstWorkingDate(weekdays);

    if (first == null) return;

    final today = _now();

    final picked = await showDatePicker(
      context: context,
      initialDate: (_date != null && weekdays.contains(_date!.weekday - 1))
          ? _date!
          : first,
      firstDate: DateTime(today.year, today.month, today.day),
      lastDate: today.add(const Duration(days: 90)),
      helpText: 'اختر يوماً من أيام دوام المزوّد',
      selectableDayPredicate: (d) => weekdays.contains(d.weekday - 1),
    );

    if (picked == null) return;

    setState(() {
      _date = picked;
      _selected = null;
    });

    _loadSlots();
  }

  void _loadSlots() {
    if (_date == null) return;

    final future = _availabilityService.slots(widget.providerId, _date!);
    // The FutureBuilder shows the error; this only stops Dart from also
    // reporting it as "unhandled" when it arrives before the next frame.
    future.ignore();

    setState(() {
      _slotsFuture = future;
    });
  }

  List<DaySlot> _visibleSlots(DaySlots day) {
    final now = _now();

    return day.slots.where((s) {
      final start = DateTime(
        _date!.year,
        _date!.month,
        _date!.day,
        s.startHour,
        s.startMinute,
      );

      if (!start.isAfter(now)) return false;

      if (_hideBookedSlots && s.isBooked) return false;

      return true;
    }).toList();
  }

  // Bottom Sheet for choosing an appointment time
  Future<void> _showSlotSheet(DaySlots day) async {
    final slots = _visibleSlots(day);
    final available = slots.where((s) => !s.isBooked).toList();

    if (available.isEmpty) {
      _showMessage('لا توجد أوقات متاحة في هذا اليوم.');
      return;
    }

    DaySlot? tempSelected = _selected;

    final result = await showModalBottomSheet<DaySlot>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final colors = Theme.of(context).colorScheme;

        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  12,
                  20,
                  MediaQuery.of(context).viewInsets.bottom + 20,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colors.outlineVariant,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    Row(
                      children: [
                        Icon(Icons.access_time_rounded, color: colors.primary),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'اختر الوقت المناسب',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 6),

                    Text(
                      _date == null ? '' : formatLongDate(_date!),
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),

                    const SizedBox(height: 20),

                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: slots.map((slot) {
                          return Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: _slotChip(slot, tempSelected, (value) {
                              setSheetState(() {
                                tempSelected = value;
                              });
                            }),
                          );
                        }).toList(),
                      ),
                    ),

                    const SizedBox(height: 18),

                    Row(
                      children: [
                        Icon(Icons.circle, size: 10, color: colors.primary),
                        const SizedBox(width: 5),
                        const Text('متاح'),
                        const SizedBox(width: 18),
                        const Icon(
                          Icons.lock_outline,
                          size: 15,
                          color: Colors.grey,
                        ),
                        const SizedBox(width: 5),
                        const Text('محجوز'),
                      ],
                    ),

                    const SizedBox(height: 24),

                    SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        onPressed: tempSelected == null
                            ? null
                            : () {
                                Navigator.pop(context, tempSelected);
                              },
                        child: const Text(
                          'اختيار هذا الوقت',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (result != null && mounted) {
      setState(() {
        _selected = result;
      });
    }
  }

  Widget _slotChip(
    DaySlot slot,
    DaySlot? selected,
    ValueChanged<DaySlot> onSelected,
  ) {
    final colors = Theme.of(context).colorScheme;

    final range = '${hmOf(slot.startTime)} - ${hmOf(slot.endTime)}';

    final isSelected = selected?.startTime == slot.startTime;

    if (slot.isBooked) {
      return Chip(
        key: Key('slot-${hmOf(slot.startTime)}'),
        avatar: const Icon(Icons.lock_outline, size: 16, color: Colors.grey),
        label: Text(
          '$range · محجوز',
          style: const TextStyle(
            color: Colors.grey,
            decoration: TextDecoration.lineThrough,
          ),
        ),
      );
    }

    return ChoiceChip(
      key: Key('slot-${hmOf(slot.startTime)}'),
      label: Text(
        range,
        style: TextStyle(
          // Unselected text follows the theme in dark mode (black87 on a
          // dark chip was unreadable); light mode is unchanged.
          color: isSelected
              ? Colors.white
              : (Theme.of(context).brightness == Brightness.dark
                    ? colors.onSurface
                    : Colors.black87),
          fontWeight: FontWeight.bold,
        ),
      ),
      selected: isSelected,
      onSelected: (_) => onSelected(slot),
      selectedColor: colors.primary,
      checkmarkColor: Colors.white,
      labelStyle: TextStyle(
        color: colors.onPrimary,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  // Confirm booking
  Future<void> _confirm() async {
    final windows = _windows;
    if (windows == null) {
      _showMessage('جارٍ تحميل بيانات المزوّد، حاول بعد لحظات.');
      return;
    }

    // Remote service without working hours: send the request with no
    // day/hour, the provider will get everything else.
    if (_isRequestWithoutTime(windows)) {
      await _send(
        successMessage: 'تم إرسال طلب الحجز! سيتواصل معك المزوّد للاتفاق على الموعد.',
      );
      return;
    }

    if (_date == null || _selected == null) {
      _showMessage('يرجى اختيار اليوم والساعة.');
      return;
    }

    final start = DateTime.utc(
      _date!.year,
      _date!.month,
      _date!.day,
      _selected!.startHour,
      _selected!.startMinute,
    );

    final end = start.add(_appointmentDuration);

    await _send(
      startTime: start,
      endTime: end,
      successMessage: 'تم إرسال طلب الحجز! سيقبله المزوّد أو يرفضه.',
    );
  }

  Future<void> _send({
    DateTime? startTime,
    DateTime? endTime,
    required String successMessage,
  }) async {
    setState(() => _loading = true);

    try {
      await _appointments.createAppointment(
        serviceId: widget.serviceId,
        startTime: startTime,
        endTime: endTime,
        customerNotes: _notesController.text.trim(),
      );

      if (!mounted) return;

      _showMessage(successMessage);

      Navigator.pop(context);
    } on ApiException catch (e) {
      _showMessage(e.message);

      if (e.statusCode == 409) {
        setState(() => _selected = null);
        _loadSlots();
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('حجز موعد'),
        centerTitle: true,
        backgroundColor: colors.surface,
      ),

      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.serviceTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 22),

            FutureBuilder<List<AvailabilityWindow>>(
              future: _availabilityFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return Text('تعذّر تحميل ساعات المزوّد: ${errorText(snapshot.error)}');
                }

                final windows = snapshot.data ?? [];

                return _buildSchedule(windows);
              },
            ),

            const SizedBox(height: 18),

            _buildNotes(),

            const SizedBox(height: 24),

            SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: _loading ? null : _confirm,
                child: _loading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'تأكيد الحجز',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),

            const SizedBox(height: 15),
          ],
        ),
      ),
    );
  }

  // Workdays Accordion + Date Picker
  Widget _buildSchedule(List<AvailabilityWindow> windows) {
    final colors = Theme.of(context).colorScheme;
    final weekdays = _workingWeekdays(windows);

    if (weekdays.isEmpty && !widget.isRemote) {
      // On-site service: customers must pick a day and hour, and there are none.
      return const Text(
        'لم يحدد المزوّد أيام دوام بعد، لا يمكن الحجز حالياً.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.red),
      );
    }

    final noTime = _isRequestWithoutTime(windows);

    final orderedDays = _displayOrder
        .where((day) => weekdays.contains(day))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (noTime)
          // Remote service, provider set no working hours: no day or hour.
          Card(
            key: const Key('no-time-note'),
            elevation: 1,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.event_available, color: colors.primary),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'هذه الخدمة عن بعد ولم يحدد المزوّد أوقات دوام. أرسل طلبك مع '
                      'ملاحظاتك وسيتواصل معك المزوّد للاتفاق على الموعد.',
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          // Workdays Accordion
          Card(
            elevation: 1,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ExpansionTile(
              initiallyExpanded: false,
              leading: Icon(Icons.calendar_view_week, color: colors.primary),
              title: const Text(
                'أيام الدوام',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              subtitle: Text(
                '${weekdays.length} أيام عمل',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
              children: [
                for (final day in orderedDays)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.event_available,
                      color: colors.primary,
                      size: 20,
                    ),
                    title: Text(kWeekdayNames[day]),
                    subtitle: Text(_hoursText(_windowsOn(windows, day))),
                  ),
              ],
            ),
          ),

        if (!noTime) ...[
          const SizedBox(height: 16),

          // Date Picker
          _PickerTile(
            icon: Icons.calendar_month,
            label: _date == null ? 'اختر تاريخ الموعد' : formatLongDate(_date!),
            onTap: () => _pickDate(windows),
          ),

          // Available slots
          if (_date != null) ...[
            const SizedBox(height: 14),
            _buildSlots(windows),
          ],
        ],
      ],
    );
  }

  String _hoursText(List<AvailabilityWindow> windows) {
    return windows
        .map((w) => 'من ${hmOf(w.startTime)} إلى ${hmOf(w.endTime)}')
        .join(' و ');
  }

  // Available times card
  Widget _buildSlots(List<AvailabilityWindow> windows) {
    final colors = Theme.of(context).colorScheme;

    return FutureBuilder<DaySlots>(
      future: _slotsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Text('تعذّر تحميل الساعات: ${errorText(snapshot.error)}');
        }

        if (!snapshot.hasData) {
          return const SizedBox.shrink();
        }

        final day = snapshot.data!;

        if (day.slots.isEmpty) {
          return const Text(
            'المزوّد لا يعمل في هذا اليوم، اختر يوماً آخر.',
            style: TextStyle(color: Colors.red),
          );
        }

        final visible = _visibleSlots(day);
        final anyFree = visible.any((s) => !s.isBooked);

        return Card(
          elevation: 1,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.access_time, color: colors.primary),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'الأوقات المتاحة',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                Text(
                  'مدة الموعد ساعة واحدة',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),

                const SizedBox(height: 14),

                Builder(builder: (context) {
                  final look = TimePickerButtonColors.of(Theme.of(context));
                  return InkWell(
                    key: const Key('time-picker-button'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: anyFree ? () => _showSlotSheet(day) : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: look.background,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: colors.outlineVariant),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.access_time_rounded, color: look.icon),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _selected == null
                                  ? 'اضغط لاختيار الوقت'
                                  : '${hmOf(_selected!.startTime)} - ${hmOf(_selected!.endTime)}',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: look.text,
                              ),
                            ),
                          ),
                          Icon(Icons.keyboard_arrow_up, color: look.icon),
                        ],
                      ),
                    ),
                  );
                }),

                if (!anyFree) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'كل ساعات هذا اليوم محجوزة أو انتهت، جرّب يوماً آخر.',
                    style: TextStyle(color: Colors.red),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // Notes
  Widget _buildNotes() {
    final colors = Theme.of(context).colorScheme;

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notes, color: colors.primary),
                const SizedBox(width: 10),
                const Text(
                  'ملاحظات',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),

            const SizedBox(height: 12),

            TextField(
              controller: _notesController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'أضف أي ملاحظات إضافية...',
                filled: true,
                fillColor: colors.surfaceContainerHighest.withValues(
                  alpha: 0.45,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Date Picker Tile
class _PickerTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PickerTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              Icon(icon, color: colors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              Icon(Icons.keyboard_arrow_down, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Colours of the «اضغط لاختيار الوقت» button.
///
/// Light mode keeps the original look (light grey field, primary-coloured
/// icons, default text colour). Dark mode uses the theme's own dark field
/// colour with the theme's on-surface colour for the text AND the icons —
/// the light grey field under the dark theme's light text made the label
/// almost invisible, and the dark theme's primary is too dark to read on a
/// dark field.
class TimePickerButtonColors {
  const TimePickerButtonColors({
    required this.background,
    required this.icon,
    this.text,
  });

  /// The light-mode field colour (unchanged from the original design).
  static const Color lightBackground = Color.fromARGB(255, 224, 219, 219);

  final Color background;
  final Color icon;

  /// null = the default text colour (light mode, as before).
  final Color? text;

  factory TimePickerButtonColors.of(ThemeData theme) {
    final colors = theme.colorScheme;
    if (theme.brightness == Brightness.dark) {
      return TimePickerButtonColors(
        background:
            theme.inputDecorationTheme.fillColor ?? colors.surfaceContainerHighest,
        icon: colors.onSurface,
        text: colors.onSurface,
      );
    }
    return TimePickerButtonColors(
      background: lightBackground,
      icon: colors.primary,
    );
  }
}
