import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/navigation_route.dart';
import '../../models/place_suggestion.dart';
import '../../models/saved_place.dart';
import '../../services/maps_navigation_service.dart';
import '../../services/saved_places_service.dart';
import '../../theme/dashboard_theme.dart';
import '../../utils/navigation_maneuvers.dart';
import '../../utils/route_progress.dart';
import 'route_options_panel.dart';
import 'compact_turn_banner.dart';
import 'turn_by_turn_banner.dart';

enum MapPanelLayout { split, navDashboard }

class MapNavigationPanel extends StatefulWidget {
  const MapNavigationPanel({super.key, this.layout = MapPanelLayout.split});

  final MapPanelLayout layout;

  @override
  State<MapNavigationPanel> createState() => _MapNavigationPanelState();
}

class _MapNavigationPanelState extends State<MapNavigationPanel>
    with AutomaticKeepAliveClientMixin {
  static const _mapsChannel = MethodChannel('com.dominar/maps');
  static const _navigationTilt = 55.0;
  static const _routeBlue = Color(0xFF0A3D91);
  static const _routeBlueSoft = Color(0x550A3D91);
  static const _routeTraveled = Color(0xFF9DBED9);
  static const _offRouteThresholdM = 100.0;
  static const _snapMaxDistanceM = 120.0;
  static const _rerouteCooldownMs = 12000;

  final _navigationService = MapsNavigationService();
  final _savedPlacesService = SavedPlacesService();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  GoogleMapController? _mapController;
  BitmapDescriptor? _navigationMarkerIcon;
  LatLng? _position;
  LatLng? _displayPosition;
  LatLng? _previousPosition;
  double _navigationHeading = 0;
  bool _followNavigationCamera = true;
  bool _locationReady = false;
  bool _mapsConfigured = false;
  bool _mapsStatusReady = false;
  bool _loadingRoute = false;
  String? _errorMessage;

  RouteResult? _activeRoute;
  List<RouteResult> _routeOptions = const [];
  int _selectedRouteIndex = 0;
  bool _isNavigating = false;
  int _currentStepIndex = 0;
  int _distanceToStepM = 0;
  LatLng? _destination;
  String _destinationLabel = '';
  int _totalDistanceMeters = 0;
  int _totalDurationSeconds = 0;
  int _navBaselineDistanceM = 0;
  int _navBaselineDurationSec = 0;
  int _routeProgressSegmentIndex = 0;
  int _trafficDurationSeconds = 0;
  int _trafficEtaFetchedAtMs = 0;
  bool _trafficEtaRefreshing = false;
  double _remainingDistanceMeters = 0;
  int _remainingDurationSeconds = 0;
  double _lastSpeedMps = 0;
  bool _rerouteInFlight = false;
  int _lastRerouteMs = 0;
  StreamSubscription<Position>? _locationSub;

  List<PlaceSuggestion> _suggestions = const [];
  SavedPlace? _homePlace;
  SavedPlace? _workPlace;
  List<SavedPlace> _recentPlaces = const [];
  SavedPlaceSlot? _pendingSavedSlot;
  Timer? _debounce;
  Timer? _trafficEtaTimer;
  Timer? _etaDisplayTimer;

  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _searchFocus.addListener(_onSearchFocusChanged);
    _createNavigationMarkerIcon();
    _initMapsStatus();
    _initLocation();
    _loadSavedPlaces();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _debounce?.cancel();
    _trafficEtaTimer?.cancel();
    _etaDisplayTimer?.cancel();
    _locationSub?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _createNavigationMarkerIcon() async {
    const size = 96;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final arrow = Path()
      ..moveTo(48, 5)
      ..lineTo(82, 86)
      ..lineTo(48, 69)
      ..lineTo(14, 86)
      ..close();

    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.42)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawPath(
      arrow,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white,
    );
    canvas.drawPath(
      arrow,
      Paint()
        ..style = PaintingStyle.fill
        ..color = _routeBlue,
    );

    final image = await recorder.endRecording().toImage(size, size);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null || !mounted) return;

    setState(() {
      _navigationMarkerIcon = BitmapDescriptor.bytes(
        data.buffer.asUint8List(),
        width: 48,
        height: 48,
      );
      if (_isNavigating && _position != null) {
        _markers = _navigationMarkers(_position!);
      }
    });
  }

  Set<Marker> _navigationMarkers(LatLng current) => {
        if (_destination != null)
          Marker(
            markerId: const MarkerId('destination'),
            position: _destination!,
            infoWindow: InfoWindow(title: _destinationLabel),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueOrange,
            ),
          ),
        Marker(
          markerId: const MarkerId('navigation-position'),
          position: _displayPosition ?? current,
          rotation: _navigationHeading,
          flat: true,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 10,
          icon: _navigationMarkerIcon ??
              BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueAzure,
              ),
        ),
      };

  Set<Polyline> _buildNavigationPolylines(
    RouteResult route,
    int segmentIndex,
    LatLng snapped,
  ) {
    final split = splitRouteAtProgress(route.points, segmentIndex, snapped);
    final polylines = <Polyline>{};

    if (split.traveled.length >= 2) {
      polylines.add(
        Polyline(
          polylineId: PolylineId('${route.id}-traveled'),
          points: split.traveled,
          color: _routeTraveled,
          width: 10,
          zIndex: 1,
        ),
      );
    }
    if (split.remaining.length >= 2) {
      polylines.add(
        Polyline(
          polylineId: PolylineId('${route.id}-remaining'),
          points: split.remaining,
          color: _routeBlue,
          width: 10,
          zIndex: 2,
        ),
      );
    }
    return polylines;
  }

  double _segmentBearing(
    List<LatLng> points,
    int segmentIndex,
    double fallback,
  ) {
    if (segmentIndex < 0 || segmentIndex >= points.length - 1) {
      return fallback;
    }
    final start = points[segmentIndex];
    final end = points[segmentIndex + 1];
    return Geolocator.bearingBetween(
      start.latitude,
      start.longitude,
      end.latitude,
      end.longitude,
    );
  }

  Future<void> _initMapsStatus() async {
    var configured = false;
    try {
      configured =
          await _mapsChannel.invokeMethod<bool>('isConfigured') ?? false;
    } catch (_) {
      configured = false;
    }
    if (!mounted) return;
    setState(() {
      _mapsConfigured = configured;
      _mapsStatusReady = true;
    });
  }

  Future<void> _initLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() {
          _locationReady = true;
          _position = const LatLng(28.6139, 77.2090);
        });
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (!mounted) return;
      setState(() {
        _position = LatLng(pos.latitude, pos.longitude);
        _locationReady = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _locationReady = true;
        _position = const LatLng(28.6139, 77.2090);
      });
    }
  }

  void _onSearchFocusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSavedPlaces() async {
    final home = await _savedPlacesService.getHome();
    final work = await _savedPlacesService.getWork();
    final recents = await _savedPlacesService.getRecents();
    if (!mounted) return;
    setState(() {
      _homePlace = home;
      _workPlace = work;
      _recentPlaces = recents;
    });
  }

  void _beginSetSavedPlace(SavedPlaceSlot slot) {
    setState(() {
      _pendingSavedSlot = slot;
      _suggestions = const [];
    });
    _searchFocus.requestFocus();
  }

  Future<void> _selectSavedPlace(SavedPlace place) async {
    _searchFocus.unfocus();
    setState(() {
      _suggestions = const [];
      _pendingSavedSlot = null;
      _searchController.text = place.description;
    });
    await _loadRoutes(place.location, place.description);
    await _savedPlacesService.addRecent(place);
    await _loadSavedPlaces();
  }

  Future<void> _persistResolvedPlace({
    required PlaceSuggestion suggestion,
    required LatLng location,
  }) async {
    final saved = SavedPlace(
      placeId: suggestion.placeId,
      description: suggestion.description,
      latitude: location.latitude,
      longitude: location.longitude,
    );

    if (_pendingSavedSlot == SavedPlaceSlot.home) {
      await _savedPlacesService.setHome(saved);
    } else if (_pendingSavedSlot == SavedPlaceSlot.work) {
      await _savedPlacesService.setWork(saved);
    } else {
      await _savedPlacesService.addRecent(saved);
    }

    await _loadSavedPlaces();
  }

  Future<void> _persistGeocodedPlace({
    required String description,
    required LatLng location,
  }) async {
    final saved = SavedPlace(
      placeId: description,
      description: description,
      latitude: location.latitude,
      longitude: location.longitude,
    );

    if (_pendingSavedSlot == SavedPlaceSlot.home) {
      await _savedPlacesService.setHome(saved);
    } else if (_pendingSavedSlot == SavedPlaceSlot.work) {
      await _savedPlacesService.setWork(saved);
    } else {
      await _savedPlacesService.addRecent(saved);
    }

    await _loadSavedPlaces();
  }

  bool get _showSearchShortcuts =>
      !_isNavigating &&
      _searchFocus.hasFocus &&
      _searchController.text.trim().length < 2;

  String get _searchHintText {
    if (_pendingSavedSlot == SavedPlaceSlot.home) {
      return 'Search to set Home…';
    }
    if (_pendingSavedSlot == SavedPlaceSlot.work) {
      return 'Search to set Work…';
    }
    return 'Search destination…';
  }

  void _dismissSearchKeyboard() {
    _searchFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Widget? _searchSuffixIcon() {
    final hasText = _searchController.text.isNotEmpty;
    final focused = _searchFocus.hasFocus;

    if (!focused && !hasText) return null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (focused)
          IconButton(
            icon: const Icon(Icons.keyboard_hide_outlined, size: 18),
            color: DashboardTheme.muted,
            tooltip: 'Hide keyboard',
            visualDensity: VisualDensity.compact,
            onPressed: _dismissSearchKeyboard,
          ),
        if (hasText)
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: DashboardTheme.muted,
            tooltip: 'Clear',
            visualDensity: VisualDensity.compact,
            onPressed: _clearRoute,
          ),
      ],
    );
  }

  double _shortcutsPanelMaxHeight(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    const topChrome = 8.0 + 52.0 + 8.0;
    final aboveKeyboard = size.height - keyboard - topChrome;
    return aboveKeyboard.clamp(96.0, 260.0);
  }

  void _onSearchChanged() {
    if (_isNavigating) return;
    if (mounted) setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final query = _searchController.text;
      if (query.trim().length < 2) {
        if (mounted) setState(() => _suggestions = const []);
        return;
      }

      final results = await _navigationService.searchPlaces(
        query,
        near: _position,
      );
      if (!mounted) return;
      setState(() {
        _suggestions = results.suggestions;
        _errorMessage = results.errorMessage;
      });
    });
  }

  Future<void> _selectSuggestion(PlaceSuggestion suggestion) async {
    _searchFocus.unfocus();
    setState(() {
      _suggestions = const [];
      _loadingRoute = true;
      _errorMessage = null;
      _searchController.text = suggestion.description;
    });

    var lookup = await _navigationService.resolvePlace(suggestion.placeId);
    if (lookup.location == null) {
      lookup = await _navigationService.geocodeAddress(suggestion.description);
    }
    if (!mounted) return;
    if (lookup.location == null || _position == null) {
      setState(() {
        _loadingRoute = false;
        _errorMessage = lookup.errorMessage ??
            'Could not resolve that place. Enable Place Details + Geocoding APIs.';
      });
      return;
    }

    await _persistResolvedPlace(
      suggestion: suggestion,
      location: lookup.location!,
    );

    final pendingSlot = _pendingSavedSlot;
    if (pendingSlot != null) {
      setState(() {
        _loadingRoute = false;
        _pendingSavedSlot = null;
        _searchController.clear();
      });
      return;
    }

    await _loadRoutes(lookup.location!, suggestion.description);
  }

  Future<void> _searchSubmitted() async {
    final query = _searchController.text.trim();
    if (query.length < 2 || _position == null) return;

    _searchFocus.unfocus();
    setState(() {
      _suggestions = const [];
      _loadingRoute = true;
      _errorMessage = null;
    });

    final lookup = await _navigationService.geocodeAddress(query);
    if (!mounted) return;
    if (lookup.location == null) {
      setState(() {
        _loadingRoute = false;
        _errorMessage = lookup.errorMessage ?? 'No results for "$query".';
      });
      return;
    }

    await _persistGeocodedPlace(
      description: query,
      location: lookup.location!,
    );

    final pendingSlot = _pendingSavedSlot;
    if (pendingSlot != null) {
      setState(() {
        _loadingRoute = false;
        _pendingSavedSlot = null;
        _searchController.clear();
      });
      return;
    }

    await _loadRoutes(lookup.location!, query);
  }

  Future<void> _loadRoutes(LatLng destination, String label) async {
    final origin = _position;
    if (origin == null) return;

    final options = await _navigationService.getMotorbikeRouteOptions(
      origin: origin,
      destination: destination,
      destinationName: label,
      trafficAware: true,
    );

    if (!mounted) return;
    if (options.routes.isEmpty) {
      setState(() {
        _loadingRoute = false;
        _errorMessage = options.errorMessage ??
            'Could not build route. Enable Routes API in Google Cloud.';
      });
      return;
    }

    setState(() {
      _loadingRoute = false;
      _routeOptions = options.routes;
      _selectedRouteIndex = 0;
      _isNavigating = false;
      _suggestions = const [];
      _destination = destination;
      _destinationLabel = label;
      _errorMessage = null;
    });

    _applySelectedRoutePreview();
    await _fitRoute(_activeRoute!.points);
  }

  void _applySelectedRoutePreview() {
    if (_routeOptions.isEmpty) return;
    final selected = _routeOptions[_selectedRouteIndex];

    final polylines = <Polyline>{};
    for (var i = 0; i < _routeOptions.length; i++) {
      final route = _routeOptions[i];
      final isSelected = i == _selectedRouteIndex;
      polylines.add(
        Polyline(
          polylineId: PolylineId(route.id),
          points: route.points,
          color: isSelected ? _routeBlue : _routeBlueSoft,
          width: isSelected ? 10 : 4,
          zIndex: isSelected ? 2 : 1,
        ),
      );
    }

    setState(() {
      _activeRoute = selected;
      _totalDistanceMeters = selected.distanceMeters;
      _totalDurationSeconds = selected.durationSeconds;
      _remainingDistanceMeters = selected.distanceMeters.toDouble();
      _remainingDurationSeconds = selected.durationSeconds;
      _currentStepIndex = 0;
      _distanceToStepM = 0;
      _markers = {
        if (_destination != null)
          Marker(
            markerId: const MarkerId('destination'),
            position: _destination!,
            infoWindow: InfoWindow(title: _destinationLabel),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueOrange,
            ),
          ),
      };
      _polylines = polylines;
    });
  }

  void _selectRouteOption(int index) {
    if (index < 0 || index >= _routeOptions.length) return;
    setState(() => _selectedRouteIndex = index);
    _applySelectedRoutePreview();
    _fitRoute(_activeRoute!.points);
  }

  void _startNavigation() {
    final route = _activeRoute;
    if (route == null || _position == null) return;

    _searchFocus.unfocus();
    _debounce?.cancel();

    final stepIndex =
        route.steps.isEmpty ? 0 : activeStepIndex(route.steps, _position!);
    final distToStep = route.steps.isEmpty
        ? 0
        : distanceToStepEnd(route.steps[stepIndex], _position!);

    setState(() {
      _isNavigating = true;
      _followNavigationCamera = true;
      _previousPosition = null;
      _suggestions = const [];
      _routeOptions = const [];
      _currentStepIndex = stepIndex;
      _distanceToStepM = distToStep;
      _navBaselineDistanceM = route.distanceMeters;
      _navBaselineDurationSec = route.durationSeconds;
      _routeProgressSegmentIndex = 0;
      _remainingDistanceMeters = route.distanceMeters.toDouble();
      _remainingDurationSeconds = route.durationSeconds;
      _trafficDurationSeconds = route.durationSeconds;
      _trafficEtaFetchedAtMs = DateTime.now().millisecondsSinceEpoch;
      _displayPosition = _position;
      final tracked = trackPositionOnRoute(
        _position!,
        route.points,
        _routeProgressSegmentIndex,
      );
      _polylines = _buildNavigationPolylines(
        route,
        tracked.segmentIndex,
        tracked.snapped,
      );
      _markers = _navigationMarkers(_position!);
    });
    _moveNavigationCamera(
      _position!,
      _navigationHeading,
      speedMps: _lastSpeedMps,
      distanceToManeuverM: _distanceToStepM,
    );
    _startRouteTracking(followCamera: true);
    _startTrafficEtaRefresh();
  }

  void _startTrafficEtaRefresh() {
    _trafficEtaTimer?.cancel();
    _etaDisplayTimer?.cancel();
    unawaited(_refreshTrafficEta());
    _trafficEtaTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => unawaited(_refreshTrafficEta()),
    );
    _etaDisplayTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isNavigating || _trafficDurationSeconds <= 0 || !mounted) return;
      setState(() {
        _remainingDurationSeconds = _liveTrafficEtaSeconds();
      });
    });
  }

  void _stopTrafficEtaRefresh() {
    _trafficEtaTimer?.cancel();
    _trafficEtaTimer = null;
    _etaDisplayTimer?.cancel();
    _etaDisplayTimer = null;
  }

  Future<void> _refreshTrafficEta() async {
    final destination = _destination;
    final origin = _position;
    if (!_isNavigating || destination == null || origin == null) return;
    if (_trafficEtaRefreshing) return;

    _trafficEtaRefreshing = true;
    try {
      final eta = await _navigationService.fetchTrafficAwareEta(
        origin: origin,
        destination: destination,
      );
      if (!mounted || eta == null) return;

      setState(() {
        _trafficDurationSeconds = eta.durationSeconds;
        _trafficEtaFetchedAtMs = DateTime.now().millisecondsSinceEpoch;
        _remainingDurationSeconds = _liveTrafficEtaSeconds();
      });
    } finally {
      _trafficEtaRefreshing = false;
    }
  }

  int _liveTrafficEtaSeconds() {
    if (_trafficDurationSeconds <= 0) {
      return _fallbackEtaSeconds(_remainingDistanceMeters);
    }
    final elapsedSec = ((DateTime.now().millisecondsSinceEpoch -
            _trafficEtaFetchedAtMs) /
        1000)
        .floor();
    return (_trafficDurationSeconds - elapsedSec)
        .clamp(0, _trafficDurationSeconds);
  }

  int _fallbackEtaSeconds(double remainingM, {double speedMps = 0}) {
    if (_navBaselineDistanceM <= 0 || _navBaselineDurationSec <= 0) {
      return _remainingDurationSeconds;
    }
    final ratio = (remainingM / _navBaselineDistanceM).clamp(0.0, 1.0);
    var eta = (_navBaselineDurationSec * ratio).round();
    if (speedMps > 2.5 && remainingM > 300) {
      final speedEta = (remainingM / speedMps).round();
      if (speedEta > 0 && speedEta <= eta * 1.35) {
        eta = ((eta * 0.55) + (speedEta * 0.45)).round();
      }
    }
    return eta.clamp(0, _navBaselineDurationSec);
  }

  void _stopNavigation() {
    _stopRouteTracking();
    _stopTrafficEtaRefresh();
    setState(() {
      _isNavigating = false;
      if (_activeRoute != null) {
        _routeOptions = [_activeRoute!];
        _selectedRouteIndex = 0;
        _applySelectedRoutePreview();
      }
    });
  }

  void _startRouteTracking({bool followCamera = false}) {
    _locationSub?.cancel();
    _locationSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 2,
      ),
    ).listen((position) async {
      final current = LatLng(position.latitude, position.longitude);
      final heading = _headingFor(position, current);
      _previousPosition = current;
      _lastSpeedMps = position.speed >= 0 ? position.speed : 0;
      _updateRouteProgress(current, heading, speedMps: _lastSpeedMps);
      if (_isNavigating) {
        unawaited(_maybeReroute(current));
      }
      if (followCamera && _followNavigationCamera) {
        await _moveNavigationCamera(
          _displayPosition ?? current,
          _navigationHeading,
          speedMps: _lastSpeedMps,
          distanceToManeuverM: _distanceToStepM,
        );
      }
    });
  }

  double _navigationZoomFor(double speedMps, int distanceToManeuverM) {
    if (distanceToManeuverM < 100) return 19.2;
    if (distanceToManeuverM < 350) return 18.4;
    if (speedMps >= 14) return 16.2; // ~50 km/h open road
    if (speedMps >= 8) return 17.0;
    return 18.0;
  }

  Future<void> _maybeReroute(LatLng current) async {
    final route = _activeRoute;
    final destination = _destination;
    if (!_isNavigating || route == null || destination == null) return;
    if (_rerouteInFlight) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastRerouteMs < _rerouteCooldownMs) return;
    if (!isOffRoute(
      current,
      route.points,
      thresholdMeters: _offRouteThresholdM,
      fromSegmentIndex: _routeProgressSegmentIndex,
    )) {
      return;
    }

    _rerouteInFlight = true;
    _lastRerouteMs = now;

    final options = await _navigationService.getMotorbikeRouteOptions(
      origin: current,
      destination: destination,
      destinationName: _destinationLabel,
      trafficAware: true,
      alternatives: false,
    );

    if (!mounted) {
      _rerouteInFlight = false;
      return;
    }

    if (options.routes.isEmpty) {
      _rerouteInFlight = false;
      if (options.errorMessage != null) {
        setState(() => _errorMessage = options.errorMessage);
      }
      return;
    }

    final rerouted = options.routes.first;
    final stepIndex =
        rerouted.steps.isEmpty ? 0 : activeStepIndex(rerouted.steps, current);
    final tracked = trackPositionOnRoute(
      current,
      rerouted.points,
      _routeProgressSegmentIndex,
    );

    setState(() {
      _activeRoute = rerouted;
      _routeOptions = const [];
      _navBaselineDistanceM = rerouted.distanceMeters;
      _navBaselineDurationSec = rerouted.durationSeconds;
      _routeProgressSegmentIndex = tracked.segmentIndex;
      _totalDistanceMeters = rerouted.distanceMeters;
      _totalDurationSeconds = rerouted.durationSeconds;
      _currentStepIndex = stepIndex;
      _distanceToStepM = rerouted.steps.isEmpty
          ? 0
          : distanceToStepEnd(rerouted.steps[stepIndex], current);
      _remainingDistanceMeters = tracked.remainingMeters;
      _remainingDurationSeconds = rerouted.durationSeconds;
      _trafficDurationSeconds = rerouted.durationSeconds;
      _trafficEtaFetchedAtMs = DateTime.now().millisecondsSinceEpoch;
      _errorMessage = null;
      _displayPosition =
          tracked.distanceMeters <= _snapMaxDistanceM ? tracked.snapped : current;
      _polylines = _buildNavigationPolylines(
        rerouted,
        tracked.segmentIndex,
        tracked.snapped,
      );
      _markers = _navigationMarkers(current);
    });

    _rerouteInFlight = false;
    unawaited(_refreshTrafficEta());
  }

  double _headingFor(Position position, LatLng current) {
    if (position.speed >= 0.8 &&
        position.heading.isFinite &&
        position.heading >= 0) {
      return position.heading;
    }
    final previous = _previousPosition;
    if (previous != null &&
        Geolocator.distanceBetween(
              previous.latitude,
              previous.longitude,
              current.latitude,
              current.longitude,
            ) >=
            1.5) {
      return Geolocator.bearingBetween(
        previous.latitude,
        previous.longitude,
        current.latitude,
        current.longitude,
      );
    }
    return _navigationHeading;
  }

  Future<void> _moveNavigationCamera(
    LatLng current,
    double heading, {
    double speedMps = 0,
    int distanceToManeuverM = 999,
  }) async {
    final controller = _mapController;
    if (controller == null || !_isNavigating) return;
    final zoom = _navigationZoomFor(speedMps, distanceToManeuverM);
    try {
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _pointAhead(current, heading, 45),
            zoom: zoom,
            tilt: _navigationTilt,
            bearing: heading,
          ),
        ),
      );
    } catch (_) {
      // The native map can briefly detach while PageView is swiping.
    }
  }

  LatLng _pointAhead(LatLng start, double bearingDegrees, double meters) {
    const earthRadiusM = 6378137.0;
    final angularDistance = meters / earthRadiusM;
    final bearing = bearingDegrees * math.pi / 180;
    final latitude = start.latitude * math.pi / 180;
    final longitude = start.longitude * math.pi / 180;

    final targetLatitude = math.asin(
      math.sin(latitude) * math.cos(angularDistance) +
          math.cos(latitude) * math.sin(angularDistance) * math.cos(bearing),
    );
    final targetLongitude = longitude +
        math.atan2(
          math.sin(bearing) * math.sin(angularDistance) * math.cos(latitude),
          math.cos(angularDistance) -
              math.sin(latitude) * math.sin(targetLatitude),
        );

    return LatLng(
      targetLatitude * 180 / math.pi,
      targetLongitude * 180 / math.pi,
    );
  }

  void _updateRouteProgress(
    LatLng current,
    double heading, {
    double speedMps = 0,
  }) {
    final route = _activeRoute;
    if (route == null || _navBaselineDistanceM <= 0) return;

    var stepIndex = _currentStepIndex;
    var distanceToStep = _distanceToStepM;

    if (_isNavigating && route.steps.isNotEmpty) {
      stepIndex = activeStepIndex(route.steps, current);
      distanceToStep = distanceToStepEnd(route.steps[stepIndex], current);
    }

    final tracked = trackPositionOnRoute(
      current,
      route.points,
      _routeProgressSegmentIndex,
    );
    final onRoute = tracked.distanceMeters <= _snapMaxDistanceM;
    final displayPos = onRoute ? tracked.snapped : current;
    var displayHeading = heading;
    if (onRoute && speedMps < 4) {
      displayHeading = _segmentBearing(
        route.points,
        tracked.segmentIndex,
        heading,
      );
    }
    final remainingM = tracked.remainingMeters;
    final remainingSec = _trafficDurationSeconds > 0
        ? _liveTrafficEtaSeconds()
        : _fallbackEtaSeconds(remainingM, speedMps: speedMps);

    if (!mounted) return;
    setState(() {
      _position = current;
      _displayPosition = displayPos;
      _navigationHeading = displayHeading;
      _routeProgressSegmentIndex = tracked.segmentIndex;
      _remainingDistanceMeters = remainingM;
      _remainingDurationSeconds = remainingSec;
      _currentStepIndex = stepIndex;
      _distanceToStepM = distanceToStep;
      if (_isNavigating) {
        _polylines = _buildNavigationPolylines(
          route,
          tracked.segmentIndex,
          displayPos,
        );
        _markers = _navigationMarkers(current);
      }
    });
  }

  void _stopRouteTracking() {
    _locationSub?.cancel();
    _locationSub = null;
  }

  Future<void> _fitRoute(List<LatLng> points) async {
    if (points.isEmpty || _mapController == null || _isNavigating) return;

    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;

    for (final point in points) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLng = math.min(minLng, point.longitude);
      maxLng = math.max(maxLng, point.longitude);
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    try {
      await _mapController!.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 56),
      );
    } catch (_) {
      await _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(points.last, 13),
      );
    }

    // Starting navigation while the route-preview animation was still
    // completing must not leave the camera zoomed out to the whole route.
    if (_isNavigating && _position != null) {
      await _moveNavigationCamera(_position!, _navigationHeading);
    }
  }

  void _clearRoute() {
    _stopRouteTracking();
    _stopTrafficEtaRefresh();
    setState(() {
      _activeRoute = null;
      _routeOptions = const [];
      _selectedRouteIndex = 0;
      _isNavigating = false;
      _currentStepIndex = 0;
      _distanceToStepM = 0;
      _destination = null;
      _destinationLabel = '';
      _totalDistanceMeters = 0;
      _totalDurationSeconds = 0;
      _navBaselineDistanceM = 0;
      _navBaselineDurationSec = 0;
      _routeProgressSegmentIndex = 0;
      _trafficDurationSeconds = 0;
      _trafficEtaFetchedAtMs = 0;
      _remainingDistanceMeters = 0;
      _remainingDurationSeconds = 0;
      _errorMessage = null;
      _markers = {};
      _polylines = {};
      _searchController.clear();
      _suggestions = const [];
    });

    if (_mapController != null && _position != null) {
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(_position!, 15),
      );
    }
  }

  Future<void> _recenterOnUser() async {
    if (_mapController == null) return;
    _followNavigationCamera = true;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final current = LatLng(pos.latitude, pos.longitude);
      setState(() => _position = current);
      if (_isNavigating) {
        await _moveNavigationCamera(current, _navigationHeading);
      } else {
        await _mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(current, 15),
        );
      }
    } catch (_) {
      if (_position != null) {
        if (_isNavigating) {
          await _moveNavigationCamera(_position!, _navigationHeading);
        } else {
          await _mapController!.animateCamera(
            CameraUpdate.newLatLngZoom(_position!, 15),
          );
        }
      }
    }
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    if (_isNavigating && _position != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _moveNavigationCamera(_position!, _navigationHeading);
      });
    }
  }

  Widget _googleMapWidget({required EdgeInsets padding}) {
    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: _displayPosition ?? _position!,
        zoom: _isNavigating
            ? _navigationZoomFor(_lastSpeedMps, _distanceToStepM)
            : 15,
        tilt: _isNavigating ? _navigationTilt : 0,
        bearing: _isNavigating ? _navigationHeading : 0,
      ),
      onMapCreated: _onMapCreated,
      myLocationEnabled: !_isNavigating,
      myLocationButtonEnabled: false,
      compassEnabled: widget.layout != MapPanelLayout.navDashboard,
      mapType: MapType.normal,
      trafficEnabled: false,
      zoomGesturesEnabled: true,
      scrollGesturesEnabled: true,
      rotateGesturesEnabled: true,
      tiltGesturesEnabled: true,
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
      },
      markers: _markers,
      polylines: _polylines,
      padding: padding,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_mapsStatusReady || !_locationReady || _position == null) {
      return Container(
        color: const Color(0xFF1A1A1A),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(color: DashboardTheme.rpmMid),
      );
    }

    if (!_mapsConfigured) {
      return Container(
        color: const Color(0xFF1A1A1A),
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: const Text(
          'Google Maps is not configured.\n\n'
          'Open ios/Flutter/Secrets.xcconfig and paste your FULL '
          'Google API key (about 39 characters, starts with AIza).\n\n'
          'Enable in Google Cloud:\n'
          'Maps SDK for iOS, Places API, Geocoding API, Directions API\n\n'
          'Then: flutter clean && flutter run',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: DashboardTheme.text,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      );
    }

    final showRouteOptions = _routeOptions.isNotEmpty && !_isNavigating;
    final showProgress = _isNavigating && _activeRoute != null;
    final navDashboard = widget.layout == MapPanelLayout.navDashboard;
    final arrived = showProgress &&
        _destination != null &&
        _activeRoute != null &&
        hasArrivedAtDestination(
          current: _position!,
          destination: _destination!,
          steps: _activeRoute!.steps,
          stepIndex: _currentStepIndex,
        );
    final bottomPanelHeight =
        showRouteOptions ? 132.0 : (showProgress ? 58.0 : 8.0);
    final recenterBottom = showRouteOptions ? 140.0 : (showProgress ? 66.0 : 8.0);
    final navStep = _isNavigating &&
            _activeRoute != null &&
            _activeRoute!.steps.isNotEmpty
        ? _activeRoute!
            .steps[_currentStepIndex.clamp(0, _activeRoute!.steps.length - 1)]
        : null;
    final nextTurn = _isNavigating &&
            _activeRoute != null &&
            _position != null
        ? nextTurnAfterCurrent(
            _activeRoute!.steps,
            _currentStepIndex,
            _position!,
          )
        : null;
    final topBannerHeight = navDashboard && _isNavigating && navStep != null
        ? (nextTurn != null ? 56.0 : 44.0)
        : 0.0;

    final mapContent = Stack(
      fit: StackFit.expand,
      children: [
        Stack(
          children: [
            _googleMapWidget(
              padding: EdgeInsets.only(
                top: _isNavigating && navStep != null
                    ? (navDashboard ? topBannerHeight + 8 : 136)
                    : 56,
                bottom: bottomPanelHeight,
              ),
            ),
        if (!_isNavigating)
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              color: DashboardTheme.screen2.withValues(alpha: 0.96),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    enabled: !_isNavigating,
                    style: const TextStyle(
                      color: DashboardTheme.text,
                      fontSize: 13,
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _searchSubmitted(),
                    decoration: InputDecoration(
                      hintText: _searchHintText,
                      hintStyle: TextStyle(
                        color: DashboardTheme.muted.withValues(alpha: 0.85),
                        fontSize: 13,
                      ),
                      prefixIcon: const Icon(
                        Icons.search,
                        color: DashboardTheme.muted,
                        size: 20,
                      ),
                      suffixIcon: _searchSuffixIcon(),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 12,
                      ),
                    ),
                  ),
                  if (_showSearchShortcuts)
                    _SearchShortcutsPanel(
                      maxHeight: _shortcutsPanelMaxHeight(context),
                      home: _homePlace,
                      work: _workPlace,
                      recents: _recentPlaces,
                      onSelect: (place) {
                        _dismissSearchKeyboard();
                        _selectSavedPlace(place);
                      },
                      onSetHome: () => _beginSetSavedPlace(SavedPlaceSlot.home),
                      onSetWork: () => _beginSetSavedPlace(SavedPlaceSlot.work),
                      onDismissKeyboard: _dismissSearchKeyboard,
                    ),
                  if (_suggestions.isNotEmpty && !_isNavigating)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _suggestions.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                        itemBuilder: (context, index) {
                          final item = _suggestions[index];
                          return ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: const Icon(
                              Icons.place_outlined,
                              color: DashboardTheme.gearRing,
                              size: 18,
                            ),
                            title: Text(
                              item.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: DashboardTheme.text,
                                fontSize: 12,
                              ),
                            ),
                            onTap: () => _selectSuggestion(item),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (_isNavigating && navStep != null && !navDashboard)
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: TurnByTurnBanner(
              step: navStep,
              distanceMeters: _distanceToStepM,
              onStop: _stopNavigation,
            ),
          ),
        if (_isNavigating && navDashboard && navStep != null)
          Positioned(
            top: 6,
            left: 8,
            right: 8,
            child: CompactTurnBanner(
              step: navStep,
              distanceMeters: _distanceToStepM,
              thenLabel: nextTurn != null
                  ? 'Then ${formatMetersAhead(nextTurn.distanceMeters)} · ${nextTurn.step.instruction}'
                  : null,
            ),
          ),
        if (_loadingRoute)
          const Positioned(
            top: 72,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              minHeight: 2,
              color: DashboardTheme.rpmMid,
              backgroundColor: Colors.transparent,
            ),
          ),
        if (showRouteOptions)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: RouteOptionsPanel(
              routes: _routeOptions,
              selectedIndex: _selectedRouteIndex,
              onSelect: _selectRouteOption,
              onStart: _startNavigation,
            ),
          ),
        if (showProgress)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: FractionallySizedBox(
                widthFactor: navDashboard ? 1.0 : 0.5,
                child: RouteProgressBar(
                  progress: _navBaselineDistanceM > 0
                      ? 1 -
                          (_remainingDistanceMeters / _navBaselineDistanceM)
                              .clamp(0.0, 1.0)
                      : 0,
                  distanceLabel: arrived
                      ? 'Arrived'
                      : formatDistanceLeft(_remainingDistanceMeters),
                  durationLabel: arrived
                      ? ''
                      : formatDurationLeft(_remainingDurationSeconds),
                  arrivalTimeLabel: arrived
                      ? null
                      : formatArrivalTime(_remainingDurationSeconds),
                  onExit: _stopNavigation,
                ),
              ),
            ),
          ),
        if (_errorMessage != null)
          Positioned(
            bottom: showRouteOptions ? 42 : (showProgress ? 60 : 8),
            left: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: DashboardTheme.rpmHot.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
        Positioned(
          bottom: recenterBottom,
          right: 8,
          child: FloatingActionButton.small(
            heroTag: 'recenter_map',
            backgroundColor: DashboardTheme.screen2,
            foregroundColor: DashboardTheme.gearRing,
            onPressed: _recenterOnUser,
            child: const Icon(Icons.my_location, size: 18),
          ),
        ),
            ],
          ),
        if (navDashboard) ...[
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 22,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      DashboardTheme.bg.withValues(alpha: 0.72),
                      DashboardTheme.bg.withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 22,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerRight,
                    end: Alignment.centerLeft,
                    colors: [
                      DashboardTheme.bg.withValues(alpha: 0.72),
                      DashboardTheme.bg.withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ] else
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 14,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      DashboardTheme.bg.withValues(alpha: 0.28),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    if (navDashboard) {
      return mapContent;
    }

    return ClipRRect(
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(22),
        bottomLeft: Radius.circular(22),
      ),
      child: mapContent,
    );
  }
}

class _SearchShortcutsPanel extends StatelessWidget {
  const _SearchShortcutsPanel({
    required this.maxHeight,
    required this.home,
    required this.work,
    required this.recents,
    required this.onSelect,
    required this.onSetHome,
    required this.onSetWork,
    required this.onDismissKeyboard,
  });

  final double maxHeight;
  final SavedPlace? home;
  final SavedPlace? work;
  final List<SavedPlace> recents;
  final ValueChanged<SavedPlace> onSelect;
  final VoidCallback onSetHome;
  final VoidCallback onSetWork;
  final VoidCallback onDismissKeyboard;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: _SavedPlaceChip(
                    icon: Icons.home_outlined,
                    label: 'Home',
                    place: home,
                    onTap: home != null ? () => onSelect(home!) : onSetHome,
                    onEdit: onSetHome,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SavedPlaceChip(
                    icon: Icons.work_outline,
                    label: 'Work',
                    place: work,
                    onTap: work != null ? () => onSelect(work!) : onSetWork,
                    onEdit: onSetWork,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
          if (recents.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
              child: Row(
                children: [
                  Text(
                    'Recent',
                    style: TextStyle(
                      color: DashboardTheme.muted.withValues(alpha: 0.85),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onDismissKeyboard,
                    icon: const Icon(Icons.keyboard_hide_outlined, size: 14),
                    label: const Text('Hide keyboard'),
                    style: TextButton.styleFrom(
                      foregroundColor: DashboardTheme.muted,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      textStyle: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            for (final place in recents) ...[
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
              _ShortcutTile(
                icon: Icons.history,
                title: place.description,
                subtitle: null,
                onTap: () => onSelect(place),
              ),
            ],
          ] else
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onDismissKeyboard,
                  icon: const Icon(Icons.keyboard_hide_outlined, size: 14),
                  label: const Text('Hide keyboard'),
                  style: TextButton.styleFrom(
                    foregroundColor: DashboardTheme.muted,
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SavedPlaceChip extends StatelessWidget {
  const _SavedPlaceChip({
    required this.icon,
    required this.label,
    required this.place,
    required this.onTap,
    required this.onEdit,
  });

  final IconData icon;
  final String label;
  final SavedPlace? place;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final address = place?.description ?? 'Add';
    return Material(
      color: Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            children: [
              Icon(icon, color: DashboardTheme.gearRing, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: DashboardTheme.text,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: DashboardTheme.muted.withValues(alpha: 0.85),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 14),
                color: DashboardTheme.muted,
                tooltip: 'Change',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: onEdit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShortcutTile extends StatelessWidget {
  const _ShortcutTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onEdit,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
      leading: Icon(icon, color: DashboardTheme.gearRing, size: 18),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: DashboardTheme.text,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: DashboardTheme.muted.withValues(alpha: 0.9),
                fontSize: 11,
              ),
            ),
      trailing: onEdit == null
          ? null
          : IconButton(
              icon: const Icon(Icons.edit_outlined, size: 16),
              color: DashboardTheme.muted,
              tooltip: 'Change',
              visualDensity: VisualDensity.compact,
              onPressed: onEdit,
            ),
      onTap: onTap,
    );
  }
}

class RouteProgressBar extends StatelessWidget {
  const RouteProgressBar({
    super.key,
    required this.progress,
    required this.distanceLabel,
    required this.durationLabel,
    this.arrivalTimeLabel,
    this.onExit,
    this.embedded = false,
  });

  final double progress;
  final String distanceLabel;
  final String durationLabel;
  final String? arrivalTimeLabel;
  final VoidCallback? onExit;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: embedded ? 52 : 54,
      margin: embedded
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(6, 0, 6, 6),
      decoration: BoxDecoration(
        color: embedded ? DashboardTheme.screen : const Color(0xFF142218),
        borderRadius: embedded ? null : BorderRadius.circular(8),
        border: Border(
          top: embedded
              ? BorderSide(color: Colors.white.withValues(alpha: 0.1))
              : BorderSide.none,
          left: embedded
              ? BorderSide.none
              : BorderSide(
                  color: const Color(0xFF35E36C).withValues(alpha: 0.35),
                ),
          right: embedded
              ? BorderSide.none
              : BorderSide(
                  color: const Color(0xFF35E36C).withValues(alpha: 0.35),
                ),
          bottom: embedded
              ? BorderSide.none
              : BorderSide(
                  color: const Color(0xFF35E36C).withValues(alpha: 0.35),
                ),
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: Row(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: Container(
                      color: embedded
                          ? DashboardTheme.rpmMid.withValues(alpha: 0.35)
                          : const Color(0xFF35E36C),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 5,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            distanceLabel,
                            maxLines: 1,
                            softWrap: false,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              height: 1,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 6),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (durationLabel.isNotEmpty)
                        Expanded(
                          flex: 4,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              durationLabel,
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                height: 1,
                                shadows: [
                                  Shadow(color: Colors.black87, blurRadius: 6),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (arrivalTimeLabel != null) ...[
            Container(
              width: 1,
              margin: const EdgeInsets.symmetric(vertical: 8),
              color: Colors.white.withValues(alpha: 0.14),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'ETA',
                    style: TextStyle(
                      color: DashboardTheme.muted.withValues(alpha: 0.9),
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    arrivalTimeLabel!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      shadows: [
                        Shadow(color: Colors.black87, blurRadius: 6),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (onExit != null)
            IconButton(
              onPressed: onExit,
              icon: const Icon(Icons.close_rounded, size: 22),
              color: DashboardTheme.muted,
              tooltip: 'Exit navigation',
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
        ],
      ),
    );
  }
}
