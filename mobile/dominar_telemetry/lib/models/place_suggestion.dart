import 'package:google_maps_flutter/google_maps_flutter.dart';

class PlaceSuggestion {
  const PlaceSuggestion({
    required this.placeId,
    required this.description,
  });

  final String placeId;
  final String description;
}

class MapsSearchResult {
  const MapsSearchResult({
    required this.suggestions,
    this.errorMessage,
  });

  final List<PlaceSuggestion> suggestions;
  final String? errorMessage;

  bool get hasError => errorMessage != null;
}

class MapsLookupResult {
  const MapsLookupResult({this.location, this.errorMessage});

  final LatLng? location;
  final String? errorMessage;
}
