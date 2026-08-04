import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_place.dart';

class SavedPlacesService {
  static const _homeKey = 'saved_place_home';
  static const _workKey = 'saved_place_work';
  static const _recentKey = 'saved_places_recent';
  static const _maxRecents = 8;

  Future<SavedPlace?> getHome() async {
    final prefs = await SharedPreferences.getInstance();
    return _readPlace(prefs.getString(_homeKey));
  }

  Future<SavedPlace?> getWork() async {
    final prefs = await SharedPreferences.getInstance();
    return _readPlace(prefs.getString(_workKey));
  }

  Future<List<SavedPlace>> getRecents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_recentKey) ?? const [];
    return raw.map(_readPlace).whereType<SavedPlace>().toList();
  }

  Future<void> setHome(SavedPlace place) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_homeKey, jsonEncode(place.toJson()));
  }

  Future<void> setWork(SavedPlace place) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_workKey, jsonEncode(place.toJson()));
  }

  Future<void> clearHome() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_homeKey);
  }

  Future<void> clearWork() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_workKey);
  }

  Future<void> addRecent(SavedPlace place) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_recentKey) ?? const [];
    final encoded = jsonEncode(place.toJson());

    final filtered = existing.where((item) {
      final parsed = _readPlace(item);
      if (parsed == null) return false;
      return parsed.placeId != place.placeId &&
          parsed.description != place.description;
    }).toList();

    final updated = [encoded, ...filtered].take(_maxRecents).toList();
    await prefs.setStringList(_recentKey, updated);
  }

  Future<void> removeRecent(SavedPlace place) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_recentKey) ?? const [];
    final updated = existing.where((item) {
      final parsed = _readPlace(item);
      if (parsed == null) return false;
      return parsed.placeId != place.placeId &&
          parsed.description != place.description;
    }).toList();
    await prefs.setStringList(_recentKey, updated);
  }

  SavedPlace? _readPlace(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final place = SavedPlace.fromJson(json);
      if (place.description.isEmpty) return null;
      return place;
    } catch (_) {
      return null;
    }
  }
}
