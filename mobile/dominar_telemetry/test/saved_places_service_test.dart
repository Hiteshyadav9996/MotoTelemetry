import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dominar_telemetry/models/saved_place.dart';
import 'package:dominar_telemetry/services/saved_places_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('SavedPlacesService stores home, work, and recents', () async {
    const home = SavedPlace(
      placeId: 'home',
      description: 'Home address',
      latitude: 28.61,
      longitude: 77.20,
    );
    const work = SavedPlace(
      placeId: 'work',
      description: 'Office',
      latitude: 28.62,
      longitude: 77.21,
    );
    const recent = SavedPlace(
      placeId: 'cafe',
      description: 'Coffee shop',
      latitude: 28.63,
      longitude: 77.22,
    );

    final service = SavedPlacesService();
    await service.setHome(home);
    await service.setWork(work);
    await service.addRecent(recent);

    expect((await service.getHome())?.description, 'Home address');
    expect((await service.getWork())?.description, 'Office');
    expect((await service.getRecents()).length, 1);
    expect((await service.getRecents()).first.description, 'Coffee shop');
  });
}
