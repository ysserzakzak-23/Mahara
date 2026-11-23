import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/api_config.dart';
import '../../core/utils/price_format.dart';
import '../../core/utils/phone_utils.dart';
import '../../shared/widgets/full_screen_image_viewer.dart';
import '../../shared/widgets/whatsapp_glyph.dart';
import '../service/data/catalog_service.dart';
import '../service/data/portfolio_service.dart';
import '../service/data/service_models.dart';
import '../service/service_details_screen.dart';
import 'data/public_profile_service.dart';
import '../../core/utils/error_text.dart';
import '../../core/utils/image_sizing.dart';

/// Read-only profile a customer can visit from a service's details page
/// (tap the provider's name/avatar) to see who they're booking with: their
/// info, their other services, and a gallery of their past-work photos
/// pulled from all of their services' portfolios.
class ProviderProfileScreen extends StatefulWidget {
  final int providerId;

  /// Optional overrides, mainly so widget tests can inject a fake backend.
  final PublicProfileService? publicProfileService;
  final CatalogService? catalogService;
  final PortfolioService? portfolioService;
  final Widget Function(int serviceId)? detailsBuilder;
  final Future<bool> Function(Uri uri)? urlLauncher;

  /// App-bar title; "ملف العميل" when a provider opens a customer's profile.
  final String title;

  const ProviderProfileScreen({
    super.key,
    required this.providerId,
    this.title = 'ملف المزوّد',
    this.publicProfileService,
    this.catalogService,
    this.portfolioService,
    this.detailsBuilder,
    this.urlLauncher,
  });

  @override
  State<ProviderProfileScreen> createState() => _ProviderProfileScreenState();
}

class _ProviderProfileScreenState extends State<ProviderProfileScreen> {
  late final PublicProfileService _publicProfile =
      widget.publicProfileService ?? PublicProfileService();
  late final CatalogService _catalog =
      widget.catalogService ?? CatalogService();
  late final PortfolioService _portfolio =
      widget.portfolioService ?? PortfolioService();

  late Future<ServiceProvider> _profileFuture;
  late Future<List<ServiceListItem>> _servicesFuture;

  @override
  void initState() {
    super.initState();
    _profileFuture = _publicProfile.getProfile(widget.providerId);
    _servicesFuture = _catalog.servicesByProvider(widget.providerId);
    // Only listened to once the profile has loaded; if it fails first, don't
    // report it as unhandled (the FutureBuilder shows the error later).
    _servicesFuture.ignore();
  }

  /// Combines the portfolio galleries of every service this provider offers
  /// into a single "previous work" grid for their profile.
  Future<List<PortfolioItem>> _loadCombinedPortfolio(
      List<ServiceListItem> services) async {
    final all = <PortfolioItem>[];
    for (final s in services) {
      try {
        all.addAll(await _portfolio.list(s.id));
      } catch (_) {
        // A single service's portfolio failing to load shouldn't blank out
        // the rest of the gallery.
      }
    }
    return all;
  }

  Future<void> _openWhatsApp(String phoneNumber) async {
    final uri = whatsAppUri(phoneNumber);
    if (uri == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("رقم جوال هذا المزوّد غير صالح.")),
      );
      return;
    }
    final launch =
        widget.urlLauncher ??
        (Uri u) => launchUrl(u, mode: LaunchMode.externalApplication);
    final opened = await launch(uri);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("تعذّر فتح واتساب.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        titleSpacing: -2,
        backgroundColor: const Color.fromARGB(0, 77, 75, 75),
      ),
      body: FutureBuilder<ServiceProvider>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(errorText(snapshot.error), textAlign: TextAlign.center),
              ),
            );
          }
          return _buildContent(snapshot.data!);
        },
      ),
    );
  }

  Widget _buildContent(ServiceProvider provider) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          GestureDetector(
            onTap: provider.avatarUrl == null
                ? null
                : () => Navigator.of(context).push(
                      FullScreenImageViewer.route(
                        imageUrl: ApiConfig.resolveUrl(provider.avatarUrl!),
                      ),
                    ),
            child: CircleAvatar(
              radius: 50,
              backgroundColor: Colors.grey.shade300,
              backgroundImage: provider.avatarUrl != null
                  ? sizedNetworkImage(
                      context,
                      ApiConfig.resolveUrl(provider.avatarUrl!),
                      longestSide: 100,   // radius 50
                    )
                  : null,
              child: provider.avatarUrl == null
                  ? const Icon(Icons.person, size: 45)
                  : null,
            ),
          ),
          const SizedBox(height: 15),
          Text(
            provider.displayName,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          if (provider.city != null) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.location_on, size: 18, color: Colors.grey),
                const SizedBox(width: 4),
                Text(provider.city!, style: const TextStyle(color: Colors.grey)),
              ],
            ),
          ],
          if (provider.phoneNumber != null &&
              provider.phoneNumber!.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            _PhoneRow(
              phone: provider.phoneNumber!.trim(),
              onCopied: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('تم نسخ الرقم.')),
              ),
            ),
          ],
          if (provider.phoneNumber != null &&
              whatsAppUri(provider.phoneNumber) != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _openWhatsApp(provider.phoneNumber!),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366), // WhatsApp green
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const WhatsAppGlyph(),
                label: const Text(
                  "راسله على واتساب",
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
          const SizedBox(height: 25),
          const Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              "نبذة",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              (provider.bio?.isNotEmpty ?? false) ? provider.bio! : "لا توجد نبذة بعد.",
            ),
          ),
          const SizedBox(height: 25),
          const Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              "الخدمات",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 10),
          FutureBuilder<List<ServiceListItem>>(
            future: _servicesFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: LinearProgressIndicator(),
                );
              }
              if (snapshot.hasError) {
                return Text(errorText(snapshot.error));
              }
              final services = snapshot.data ?? [];
              if (services.isEmpty) {
                return const Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text("لم تُنشر أي خدمات بعد."),
                );
              }
              return Column(
                children: [
                  for (final s in services)
                    Card(
                      child: ListTile(
                        title: Text(s.title),
                        subtitle: Text(formatPrice(s.price)),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  widget.detailsBuilder?.call(s.id) ??
                                  ServiceDetailsScreen(serviceId: s.id),
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 15),
                  const Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      "أعمال سابقة",
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FutureBuilder<List<PortfolioItem>>(
                    future: _loadCombinedPortfolio(services),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const LinearProgressIndicator();
                      }
                      final items = snapshot.data ?? [];
                      if (items.isEmpty) {
                        return const Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text("لا توجد صور أعمال سابقة بعد."),
                        );
                      }
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                        itemCount: items.length,
                        itemBuilder: (_, i) => GestureDetector(
                          onTap: () => Navigator.of(context).push(
                            FullScreenImageViewer.route(
                              imageUrl: ApiConfig.resolveUrl(items[i].imageUrl),
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.network(
                              ApiConfig.resolveUrl(items[i].imageUrl),
                              fit: BoxFit.cover,
                              // A tile of the 3-column grid.
                              cacheWidth: decodePixels(
                                context,
                                MediaQuery.sizeOf(context).width / 3,
                              ),
                              errorBuilder: (_, _, _) => Container(
                                color: Colors.grey.shade300,
                                child: const Icon(Icons.broken_image),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}


/// The phone number itself (selectable, and a copy button), shown above the
/// WhatsApp button so it can be copied and used without opening WhatsApp.
class _PhoneRow extends StatelessWidget {
  const _PhoneRow({required this.phone, required this.onCopied});

  final String phone;
  final VoidCallback onCopied;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.phone, size: 18, color: Colors.grey),
        const SizedBox(width: 6),
        Directionality(
          textDirection: TextDirection.ltr,
          child: SelectableText(
            phone,
            key: const Key('provider-phone'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        IconButton(
          tooltip: 'نسخ الرقم',
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: phone));
            onCopied();
          },
        ),
      ],
    );
  }
}
