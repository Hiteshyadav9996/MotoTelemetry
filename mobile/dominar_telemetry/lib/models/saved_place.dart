import 'package:google_maps_flutter/google_maps_flutter.dart';

enum SavedPlaceSlot { home, work }

class SavedPlace {
  const SavedPlace({
    required this.placeId,
    required this.description,
    required this.latitude,
    required this.longitude,
  });

  final String placeId;
  final String description;
  final double latitude;
  final double longitude;

  LatLng get location => LatLng(latitude, longitude);

  Map<String, dynamic> toJson() => {
        'placeId': placeId,
        'description': description,
        'latitude': latitude,
        'longitude': longitude,
      };

  factory SavedPlace.fromJson(Map<String, dynamic> json) {
    return SavedPlace(
      placeId: json['placeId'] as String? ?? '',
      description: json['description'] as String? ?? '',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
    );
  }

  SavedPlace copyWith({
    String? placeId,
    String? description,
    double? latitude,
    double? longitude,
  }) {
    return SavedPlace(
      placeId: placeId ?? this.placeId,
      description: description ?? this.description,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
    );
  }
}
