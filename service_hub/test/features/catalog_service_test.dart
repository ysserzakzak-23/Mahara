import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';

CatalogService serviceFor(FakeBackend backend) => CatalogService(
      apiClient: ApiClient(httpClient: backend.client, tokenStore: TokenStore()),
    );

Map<String, dynamic> serviceDetailJson() => {
      'id': 100,
      'title': 'Fix pipes',
      'description': 'desc',
      'price': '25.50',
      'price_unit': 'hour',
      'status': 'active',
      'category': categoryJson(),
      'provider': providerJson(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The category list is cached across CatalogService instances, so each
  // test starts from an empty cache rather than another test's list.
  setUp(() {
    CatalogService.invalidateCategoriesCache();
    SharedPreferences.setMockInitialValues({'access_token': 'acc'});
  });

  group('reading', () {
    test('categories are fetched without auth', () async {
      final backend = FakeBackend([categoryJson(), categoryJson(id: 2, name: 'كهرباء')]);
      final list = await serviceFor(backend).categories();

      expect(backend.last.url.path, endsWith('/categories'));
      expect(backend.last.headers.containsKey('Authorization'), isFalse);
      expect(list.map((c) => c.name), ['سباكة', 'كهرباء']);
    });

    test('services() without filters has no query string', () async {
      final backend = FakeBackend([serviceListItemJson()]);
      await serviceFor(backend).services();
      expect(backend.last.url.hasQuery, isFalse);
    });

    test('services() sends category and (unicode) city filters', () async {
      final backend = FakeBackend(<dynamic>[]);
      await serviceFor(backend).services(categoryId: 3, city: 'دمشق');

      expect(backend.last.url.queryParameters['category_id'], '3');
      expect(backend.last.url.queryParameters['city'], 'دمشق');
    });

    test('an empty city is ignored', () async {
      final backend = FakeBackend(<dynamic>[]);
      await serviceFor(backend).services(city: '');
      expect(backend.last.url.hasQuery, isFalse);
    });

    test('service(id) and servicesByProvider(id) use the right paths', () async {
      var backend = FakeBackend(serviceDetailJson());
      final detail = await serviceFor(backend).service(100);
      expect(backend.last.url.path, endsWith('/services/100'));
      expect(detail.price, 25.5);

      backend = FakeBackend([serviceListItemJson()]);
      await serviceFor(backend).servicesByProvider(10);
      expect(backend.last.url.path, endsWith('/services/provider/10'));
    });
  });

  group('search', () {
    test('searchNearby sends coordinates, default radius and the token', () async {
      final backend = FakeBackend([serviceListItemJson()..['distance_km'] = 1.5]);
      final list = await serviceFor(backend)
          .searchNearby(latitude: 33.5, longitude: 36.3);

      final q = backend.last.url.queryParameters;
      expect(backend.last.url.path, endsWith('/search/services'));
      expect(q['latitude'], '33.5');
      expect(q['longitude'], '36.3');
      expect(q['radius_km'], '25.0');
      expect(q.containsKey('category_id'), isFalse);
      expect(backend.last.headers['Authorization'], 'Bearer acc');
      expect(list.single.distanceKm, 1.5);
    });

    test('searchNearby passes custom radius and category', () async {
      final backend = FakeBackend(<dynamic>[]);
      await serviceFor(backend).searchNearby(
        latitude: 1, longitude: 2, radiusKm: 5, categoryId: 4,
      );
      expect(backend.last.url.queryParameters['radius_km'], '5.0');
      expect(backend.last.url.queryParameters['category_id'], '4');
    });

    test('searchSemantic encodes Arabic text so it round-trips', () async {
      final backend = FakeBackend(<dynamic>[]);
      await serviceFor(backend).searchSemantic(query: 'سباك لتصليح مواسير');

      expect(backend.last.url.queryParameters['q'], 'سباك لتصليح مواسير');
      expect(backend.last.url.queryParameters['threshold'], '0.35');
      expect(backend.last.url.queryParameters['limit'], '20');
    });

    test('searchSmart sends Arabic text, filters and limit', () async {
      final backend = FakeBackend(<dynamic>[]);
      await serviceFor(backend)
          .searchSmart(query: 'بدي أصلح حنفية', categoryId: 3, city: 'دمشق');

      expect(backend.last.url.path, endsWith('/search/smart'));
      expect(backend.last.url.queryParameters, {
        'q': 'بدي أصلح حنفية',
        'limit': '30',
        'category_id': '3',
        'city': 'دمشق',
      });
    });

    test('searchSmart omits unset filters and parses the results', () async {
      final backend = FakeBackend([serviceListItemJson(id: 7)]);
      final results = await serviceFor(backend).searchSmart(query: 'سباك');

      expect(backend.last.url.queryParameters.keys, containsAll(['q', 'limit']));
      expect(backend.last.url.queryParameters.containsKey('city'), isFalse);
      expect(backend.last.url.queryParameters.containsKey('category_id'), isFalse);
      expect(results.single.id, 7);
    });

    test('searchSemantic keeps special characters intact', () async {
      final backend = FakeBackend(<dynamic>[]);
      await serviceFor(backend).searchSemantic(query: 'a&b=c d');
      expect(backend.last.url.queryParameters['q'], 'a&b=c d');
    });
  });

  group('writing', () {
    test('createService sends required fields and skips unset optionals', () async {
      final backend = FakeBackend(serviceDetailJson(), status: 201);
      await serviceFor(backend).createService(
        categoryId: 1, description: 'D', price: 10,
      );

      expect(backend.last.method, 'POST');
      expect(backend.lastJsonBody, {
        'category_id': 1,
        'description': 'D',
        'price': 10.0,
        'price_unit': 'fixed',
        'is_remote': false,
      });
    });

    test('createService without a price sends no price at all (never 0) and no name',
        () async {
      final backend = FakeBackend(serviceDetailJson(), status: 201);
      await serviceFor(backend).createService(categoryId: 1, description: 'D');

      expect(backend.lastJsonBody.containsKey('price'), isFalse);
      expect(backend.lastJsonBody.containsKey('title'), isFalse);
    });

    test('updateService(removePrice: true) sends an explicit null price', () async {
      final backend = FakeBackend(serviceDetailJson());
      await serviceFor(backend).updateService(100, removePrice: true);
      expect(backend.lastJsonBody, {'price': null});
    });

    test('updateService: a given price wins over removePrice', () async {
      final backend = FakeBackend(serviceDetailJson());
      await serviceFor(backend).updateService(100, price: 12, removePrice: true);
      expect(backend.lastJsonBody, {'price': 12.0});
    });

    test('updateService without price arguments leaves the price alone', () async {
      final backend = FakeBackend(serviceDetailJson());
      await serviceFor(backend).updateService(100, status: 'active');
      expect(backend.lastJsonBody.containsKey('price'), isFalse);
    });

    test('createService includes optional fields when given', () async {
      final backend = FakeBackend(serviceDetailJson(), status: 201);
      await serviceFor(backend).createService(
        categoryId: 9, description: 'D', price: 10,
        priceUnit: 'hour', coverImageUrl: '/uploads/c.jpg', isRemote: true,
        latitude: 33.5, longitude: 36.3, customCategoryLabel: 'سباك',
      );

      expect(backend.lastJsonBody, containsPair('custom_category_label', 'سباك'));
      expect(backend.lastJsonBody, containsPair('latitude', 33.5));
      expect(backend.lastJsonBody, containsPair('is_remote', true));
      expect(backend.lastJsonBody, containsPair('cover_image_url', '/uploads/c.jpg'));
    });

    test('updateService sends only the changed fields (PATCH)', () async {
      final backend = FakeBackend(serviceDetailJson());
      await serviceFor(backend).updateService(100, title: 'New', status: 'inactive');

      expect(backend.last.method, 'PATCH');
      expect(backend.last.url.path, endsWith('/services/100'));
      expect(backend.lastJsonBody, {'title': 'New', 'status': 'inactive'});
    });

    test('updateService can send falsy values (price 0, isRemote false)', () async {
      final backend = FakeBackend(serviceDetailJson());
      await serviceFor(backend).updateService(100, price: 0, isRemote: false);
      expect(backend.lastJsonBody, {'price': 0.0, 'is_remote': false});
    });

    test('deleteService issues DELETE', () async {
      final backend = FakeBackend(null, status: 204);
      await serviceFor(backend).deleteService(100);

      expect(backend.last.method, 'DELETE');
      expect(backend.last.url.path, endsWith('/services/100'));
    });
  });
}
