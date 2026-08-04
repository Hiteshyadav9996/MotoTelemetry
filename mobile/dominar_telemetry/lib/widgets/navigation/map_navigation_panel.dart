import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart';

import '../../models/place_suggestion.dart';
import '../../models/saved_place.dart';
import '../../services/maps_navigation_service.dart';
import '../../services/navigation_session_service.dart';
import '../../services/saved_places_service.dart';
import '../../theme/dashboard_theme.dart';

enum MapPanelLayout { split, navDashboard }

/// Map panel backed by Google Navigation SDK built-in UI.
/// Flutter overlays are limited to destination search before a route exists.
class MapNavigationPanel extends StatefulWidget {
  const MapNavigationPanel({
    super.key,
    this.layout = MapPanelLayout.split,
    this.fullscreenNav = false,
    this.onFullscreenNavChanged,
  });

  final MapPanelLayout layout;
  final bool fullscreenNav;
  final ValueChanged<bool>? onFullscreenNavChanged;

  @override
  State<MapNavigationPanel> createState() => _MapNavigationPanelState();
}

class _MapNavigationPanelState extends State<MapNavigationPanel>
    with AutomaticKeepAliveClientMixin {
  static const _mapsChannel = MethodChannel('com.dominar/maps');
  static const _mapViewKey = ValueKey<String>('dominar_navigation_map');

  final _mapsService = MapsNavigationService();
  final _savedPlacesService = SavedPlacesService();
  final _navigationSession = NavigationSessionService();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  StreamSubscription<NavigationSessionState>? _sessionSub;

  LatLng? _position;
  bool _locationReady = false;
  bool _mapsConfigured = false;
  bool _mapsStatusReady = false;
  bool _sessionReady = false;
  bool _loadingRoute = false;
  bool _isSearchingPlaces = false;

  NavigationSessionState _navState = NavigationSessionState.uninitialized;

  List<PlaceSuggestion> _suggestions = const [];
  SavedPlace? _homePlace;
  SavedPlace? _workPlace;
  SavedPlaceSlot? _pendingSavedSlot;
  Timer? _debounce;

  bool get _isNavigating => _navState == NavigationSessionState.navigating;
  bool get _routeReady => _navState == NavigationSessionState.routeReady;
  bool get _googleUiActive => _routeReady || _isNavigating;

  /// Destination search only before Google Navigation takes over the map.
  bool get _showDestinationPicker => !_googleUiActive;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _searchFocus.addListener(_onSearchFocusChanged);
    _initMapsStatus();
    _initLocation();
    _initNavigationSession();
    _loadSavedPlaces();
  }

  @override
  void didUpdateWidget(MapNavigationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // After expanding/collapsing side panels, re-assert Google native chrome.
    if (oldWidget.fullscreenNav != widget.fullscreenNav && _googleUiActive) {
      unawaited(_navigationSession.refreshNativeChrome());
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _debounce?.cancel();
    _sessionSub?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    // NavigationSessionService is a process-wide singleton; do not cleanup SDK here.
    super.dispose();
  }

  void _onSearchFocusChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _initNavigationSession() async {
    _sessionSub = _navigationSession.stateChanges.listen((state) {
      if (!mounted) return;
      setState(() => _navState = state);

      // Stay on RPM | map | speed. Fullscreen is only via the toggle button.
      if (state == NavigationSessionState.browse && widget.fullscreenNav) {
        widget.onFullscreenNavChanged?.call(false);
      }

      // Re-apply Google header/footer after the split layout paints.
      if (state == NavigationSessionState.routeReady ||
          state == NavigationSessionState.navigating) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(_navigationSession.refreshNativeChrome());
        });
      }

      if (state == NavigationSessionState.browse) {
        _searchController.clear();
        _suggestions = const [];
        _pendingSavedSlot = null;
      }

      if (state == NavigationSessionState.error &&
          _navigationSession.errorMessage != null) {
        _showSnack(_navigationSession.errorMessage!);
      }
    });

    final ok = await _navigationSession.initialize();
    if (!mounted) return;
    setState(() {
      _sessionReady = ok;
      _navState = _navigationSession.state;
    });
    if (!ok && _navigationSession.errorMessage != null) {
      _showSnack(_navigationSession.errorMessage!);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    if (Scaffold.maybeOf(context) == null) {
      debugPrint('[navigation] $message');
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
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
    setState(() => _mapsConfigured = configured);
    _mapsStatusReady = true;
  }

  Future<void> _initLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() => _locationReady = true);
          _showSnack('Turn on Location Services to use navigation.');
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() => _locationReady = true);
          _showSnack('Location permission is required for navigation.');
        }
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 20),
        ),
      );
      if (!mounted) return;
      setState(() {
        _position = LatLng(latitude: pos.latitude, longitude: pos.longitude);
        _locationReady = true;
      });
      unawaited(_navigationSession.recenterMap());
    } catch (_) {
      if (!mounted) return;
      setState(() => _locationReady = true);
      _showSnack(
        'Could not get GPS fix yet. Go outdoors, enable Precise Location, then reopen Nav.',
      );
    }
  }

  Future<void> _loadSavedPlaces() async {
    final home = await _savedPlacesService.getHome();
    final work = await _savedPlacesService.getWork();
    if (!mounted) return;
    setState(() {
      _homePlace = home;
      _workPlace = work;
    });
  }

  Future<void> _onViewCreated(GoogleNavigationViewController controller) async {
    await _navigationSession.attachViewController(controller);
  }

  void _beginSetSavedPlace(SavedPlaceSlot slot) {
    setState(() {
      _pendingSavedSlot = slot;
      _suggestions = const [];
    });
    _searchFocus.requestFocus();
  }

  Future<void> _goToSavedPlace(SavedPlace place) async {
    _collapseSearch();
    await _setDestination(place.location, place.description);
    await _savedPlacesService.addRecent(place);
    await _loadSavedPlaces();
  }

  Future<void> _persistPlace({
    required String placeId,
    required String description,
    required LatLng location,
  }) async {
    final saved = SavedPlace(
      placeId: placeId,
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

  String get _searchHintText {
    if (_pendingSavedSlot == SavedPlaceSlot.home) {
      return 'Search to set Home…';
    }
    if (_pendingSavedSlot == SavedPlaceSlot.work) {
      return 'Search to set Work…';
    }
    return 'Search destination…';
  }

  void _collapseSearch() {
    _debounce?.cancel();
    _searchFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    if (!mounted) return;
    setState(() {
      if (_searchController.text.trim().length < 2) {
        _suggestions = const [];
      }
    });
  }

  void _onSearchChanged() {
    if (!_showDestinationPicker) return;
    if (mounted) setState(() {});

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final query = _searchController.text.trim();
      if (query.length < 2) {
        if (mounted) {
          setState(() {
            _suggestions = const [];
            _isSearchingPlaces = false;
          });
        }
        return;
      }

      if (mounted) setState(() => _isSearchingPlaces = true);

      final results = await _mapsService.searchPlaces(query, near: _position);
      if (!mounted) return;

      setState(() {
        _isSearchingPlaces = false;
        _suggestions = results.suggestions;
      });

      if (results.hasError) {
        _showSnack(results.errorMessage!);
      } else if (results.suggestions.isEmpty) {
        _showSnack('No places found for "$query".');
      }
    });
  }

  Future<void> _selectSuggestion(PlaceSuggestion suggestion) async {
    _debounce?.cancel();
    setState(() {
      _loadingRoute = true;
      _suggestions = const [];
      _searchController.text = suggestion.description;
    });
    _collapseSearch();

    var lookup = await _mapsService.resolvePlace(suggestion.placeId);
    lookup ??= await _mapsService.geocodeAddress(suggestion.description);

    if (!mounted) return;
    if (lookup.location == null) {
      setState(() => _loadingRoute = false);
      _showSnack(
        lookup.errorMessage ??
            'Could not resolve that place. Enable Place Details + Geocoding APIs.',
      );
      return;
    }

    await _persistPlace(
      placeId: suggestion.placeId,
      description: suggestion.description,
      location: lookup.location!,
    );

    if (_pendingSavedSlot != null) {
      setState(() {
        _loadingRoute = false;
        _pendingSavedSlot = null;
        _searchController.clear();
      });
      _showSnack('Saved.');
      return;
    }

    await _setDestination(lookup.location!, suggestion.description);
  }

  Future<void> _searchSubmitted() async {
    final query = _searchController.text.trim();
    if (query.length < 2) return;

    _debounce?.cancel();
    setState(() {
      _loadingRoute = true;
      _suggestions = const [];
    });
    _collapseSearch();

    final lookup = await _mapsService.geocodeAddress(query);
    if (!mounted) return;
    if (lookup.location == null) {
      setState(() => _loadingRoute = false);
      _showSnack(lookup.errorMessage ?? 'No results for "$query".');
      return;
    }

    await _persistPlace(
      placeId: query,
      description: query,
      location: lookup.location!,
    );

    if (_pendingSavedSlot != null) {
      setState(() {
        _loadingRoute = false;
        _pendingSavedSlot = null;
        _searchController.clear();
      });
      _showSnack('Saved.');
      return;
    }

    await _setDestination(lookup.location!, query);
  }

  Future<void> _setDestination(LatLng destination, String label) async {
    _collapseSearch();
    setState(() => _loadingRoute = true);

    final error = await _navigationSession.setMotorbikeDestination(
      target: destination,
      title: label,
    );

    if (!mounted) return;
    setState(() => _loadingRoute = false);

    if (error != null) {
      _showSnack(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (!_mapsStatusReady || !_locationReady || !_sessionReady) {
      return Container(
        color: const Color(0xFF1A1A1A),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(color: DashboardTheme.rpmMid),
      );
    }

    if (_position == null) {
      return Container(
        color: const Color(0xFF1A1A1A),
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: const Text(
          'Waiting for GPS…\n\nEnable Location Services and Precise Location, '
          'then go outdoors until the map can find you.',
          textAlign: TextAlign.center,
          style: TextStyle(color: DashboardTheme.text, fontSize: 13, height: 1.5),
        ),
      );
    }

    if (!_mapsConfigured) {
      return Container(
        color: const Color(0xFF1A1A1A),
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: const Text(
          'Google Maps is not configured.\n\n'
          'Add your API key to ios/Flutter/Secrets.xcconfig and enable '
          'Navigation SDK for iOS, Maps SDK for iOS, Places API, Geocoding API.',
          textAlign: TextAlign.center,
          style: TextStyle(color: DashboardTheme.text, fontSize: 13, height: 1.5),
        ),
      );
    }

    final mapContent = Stack(
      fit: StackFit.expand,
      children: [
        GoogleMapsNavigationView(
          key: _mapViewKey,
          onViewCreated: _onViewCreated,
          initialCameraPosition: CameraPosition(
            target: _position!,
            zoom: 15,
          ),
          initialNavigationUIEnabledPreference:
              NavigationUIEnabledPreference.automatic,
        ),
        // Search / Home / Work — browse only. Hidden the moment Google nav starts.
        if (_showDestinationPicker)
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: _DestinationPicker(
              searchController: _searchController,
              searchFocus: _searchFocus,
              hintText: _searchHintText,
              isSearching: _isSearchingPlaces,
              isLoadingRoute: _loadingRoute,
              home: _homePlace,
              work: _workPlace,
              suggestions: _suggestions,
              showHomeWork: _searchFocus.hasFocus &&
                  _searchController.text.trim().length < 2,
              onSubmitted: _searchSubmitted,
              onDismissKeyboard: _collapseSearch,
              onClear: () async {
                _searchController.clear();
                setState(() => _suggestions = const []);
                await _navigationSession.clearRoute();
              },
              onSelectSuggestion: _selectSuggestion,
              onGoHome: _homePlace != null
                  ? () => _goToSavedPlace(_homePlace!)
                  : () => _beginSetSavedPlace(SavedPlaceSlot.home),
              onGoWork: _workPlace != null
                  ? () => _goToSavedPlace(_workPlace!)
                  : () => _beginSetSavedPlace(SavedPlaceSlot.work),
              onEditHome: () => _beginSetSavedPlace(SavedPlaceSlot.home),
              onEditWork: () => _beginSetSavedPlace(SavedPlaceSlot.work),
            ),
          ),
        // Fullscreen ↔ RPM|map|speed toggle (does not start/stop navigation).
        if (widget.layout == MapPanelLayout.navDashboard &&
            widget.onFullscreenNavChanged != null &&
            _googleUiActive)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Material(
                elevation: 4,
                color: const Color(0xFF1B5E20).withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => widget.onFullscreenNavChanged
                      ?.call(!widget.fullscreenNav),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          widget.fullscreenNav
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          color: Colors.white,
                          size: 18,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          widget.fullscreenNav ? 'Dashboard' : 'Full map',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    if (widget.layout == MapPanelLayout.navDashboard) {
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

/// Compact destination entry: search field, optional Home/Work row, suggestions.
class _DestinationPicker extends StatelessWidget {
  const _DestinationPicker({
    required this.searchController,
    required this.searchFocus,
    required this.hintText,
    required this.isSearching,
    required this.isLoadingRoute,
    required this.home,
    required this.work,
    required this.suggestions,
    required this.showHomeWork,
    required this.onSubmitted,
    required this.onDismissKeyboard,
    required this.onClear,
    required this.onSelectSuggestion,
    required this.onGoHome,
    required this.onGoWork,
    required this.onEditHome,
    required this.onEditWork,
  });

  final TextEditingController searchController;
  final FocusNode searchFocus;
  final String hintText;
  final bool isSearching;
  final bool isLoadingRoute;
  final SavedPlace? home;
  final SavedPlace? work;
  final List<PlaceSuggestion> suggestions;
  final bool showHomeWork;
  final VoidCallback onSubmitted;
  final VoidCallback onDismissKeyboard;
  final VoidCallback onClear;
  final ValueChanged<PlaceSuggestion> onSelectSuggestion;
  final VoidCallback onGoHome;
  final VoidCallback onGoWork;
  final VoidCallback onEditHome;
  final VoidCallback onEditWork;

  @override
  Widget build(BuildContext context) {
    final hasText = searchController.text.isNotEmpty;
    final focused = searchFocus.hasFocus;

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: DashboardTheme.screen2.withValues(alpha: 0.96),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: searchController,
            focusNode: searchFocus,
            style: const TextStyle(color: DashboardTheme.text, fontSize: 13),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => onSubmitted(),
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle: TextStyle(
                color: DashboardTheme.muted.withValues(alpha: 0.85),
                fontSize: 13,
              ),
              prefixIcon: const Icon(
                Icons.search,
                color: DashboardTheme.muted,
                size: 20,
              ),
              suffixIcon: _suffixIcon(focused, hasText),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 12,
              ),
            ),
          ),
          if (showHomeWork)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: _PlaceChip(
                      icon: Icons.home_outlined,
                      label: 'Home',
                      subtitle: home?.description ?? 'Add',
                      onTap: onGoHome,
                      onLongPress: onEditHome,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _PlaceChip(
                      icon: Icons.work_outline,
                      label: 'Work',
                      subtitle: work?.description ?? 'Add',
                      onTap: onGoWork,
                      onLongPress: onEditWork,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard_hide_outlined, size: 20),
                    color: DashboardTheme.muted,
                    tooltip: 'Hide keyboard',
                    visualDensity: VisualDensity.compact,
                    onPressed: onDismissKeyboard,
                  ),
                ],
              ),
            ),
          if (suggestions.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: suggestions.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.08),
                ),
                itemBuilder: (context, index) {
                  final item = suggestions[index];
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
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
                    onTap: () => onSelectSuggestion(item),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget? _suffixIcon(bool focused, bool hasText) {
    if (isSearching || isLoadingRoute) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: DashboardTheme.rpmMid,
          ),
        ),
      );
    }

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
            onPressed: onDismissKeyboard,
          ),
        if (hasText)
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: DashboardTheme.muted,
            tooltip: 'Clear',
            visualDensity: VisualDensity.compact,
            onPressed: onClear,
          ),
      ],
    );
  }
}

class _PlaceChip extends StatelessWidget {
  const _PlaceChip({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    required this.onLongPress,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                      subtitle,
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
            ],
          ),
        ),
      ),
    );
  }
}
