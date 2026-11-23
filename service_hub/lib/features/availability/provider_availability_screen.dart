import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import 'data/availability_models.dart';
import 'data/availability_service.dart';
import '../../core/utils/error_text.dart';

/// Lets a provider manage their own recurring weekly working hours
/// (item: "اوقات الحجوزات بيعملها كل مقدم خدمة لحال"). Only the owning
/// provider can edit their own schedule — enforced server-side by
/// comparing the path's provider_id to the authenticated user
/// (app/routers/availability.py).
class ProviderAvailabilityScreen extends StatefulWidget {
  final int providerId;

  /// Optional override, mainly so widget tests can inject a fake backend.
  final AvailabilityService? service;

  const ProviderAvailabilityScreen({
    super.key,
    required this.providerId,
    this.service,
  });

  @override
  State<ProviderAvailabilityScreen> createState() =>
      _ProviderAvailabilityScreenState();
}

class _ProviderAvailabilityScreenState
    extends State<ProviderAvailabilityScreen> {
  late final AvailabilityService _service =
      widget.service ?? AvailabilityService();
  late Future<List<AvailabilityWindow>> _future;

  @override
  void initState() {
    super.initState();
    _future = _service.list(widget.providerId);
  }

  // void _reload() {
  //   setState(() => _future = _service.list(widget.providerId));
  // }
  void _reload() {
    final next = _service.list(widget.providerId);
    setState(() {
      _future = next;
    });
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addWindow() async {
    int dayOfWeek = 0;
    TimeOfDay start = const TimeOfDay(hour: 9, minute: 0);
    TimeOfDay end = const TimeOfDay(hour: 17, minute: 0);

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            String fmt(TimeOfDay t) =>
                '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

            return AlertDialog(
              title: const Text('إضافة فترة توفر'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<int>(
                    initialValue: dayOfWeek,
                    items: [
                      for (var i = 0; i < kWeekdayNames.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(kWeekdayNames[i]),
                        ),
                    ],
                    onChanged: (v) =>
                        setDialogState(() => dayOfWeek = v ?? dayOfWeek),
                    decoration: const InputDecoration(labelText: 'اليوم'),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    title: Text('البداية: ${fmt(start)}'),
                    trailing: const Icon(Icons.access_time),
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: dialogContext,
                        initialTime: start,
                      );
                      if (picked != null) setDialogState(() => start = picked);
                    },
                  ),
                  ListTile(
                    title: Text('النهاية: ${fmt(end)}'),
                    trailing: const Icon(Icons.access_time),
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: dialogContext,
                        initialTime: end,
                      );
                      if (picked != null) setDialogState(() => end = picked);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text(
                    'إضافة',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != true) return;

    String fmt(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    try {
      await _service.create(
        widget.providerId,
        dayOfWeek: dayOfWeek,
        startTime: fmt(start),
        endTime: fmt(end),
      );
      _reload();
    } on ApiException catch (e) {
      _showMessage(e.message);
    }
  }

  Future<void> _remove(AvailabilityWindow w) async {
    try {
      await _service.deactivate(widget.providerId, w.id);
      _reload();
    } on ApiException catch (e) {
      _showMessage(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("ساعات الحجز الخاصة بي")),
      floatingActionButton: FloatingActionButton(
        onPressed: _addWindow,
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<AvailabilityWindow>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text(errorText(snapshot.error)));
          }
          final windows =
              (snapshot.data ?? []).where((w) => w.isActive).toList()
                ..sort((a, b) => a.dayOfWeek.compareTo(b.dayOfWeek));
  
          if (windows.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  "لم تحدد ساعات عمل بعد. اضغط + لإضافة فترة — "
                  "يمكن للعملاء حجزك ضمن هذه الفترات فقط.",
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: windows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final w = windows[i];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.schedule),
                  title: Text(kWeekdayNames[w.dayOfWeek]),
                  subtitle: Text(
                    '${w.startTime.substring(0, 5)} - ${w.endTime.substring(0, 5)}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _remove(w),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
