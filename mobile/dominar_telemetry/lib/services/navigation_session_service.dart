import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart';

import '../models/navigation_trip_snapshot.dart';
import 'internet_reachability.dart';

enum NavigationSessionState {
  uninitialized,
  initializing,
  browse,
  routeReady,
  navigating,
  error,
}

class NavigationSessionService {
  NavigationSessionService._();
  static final NavigationSessionService instance = NavigationSessionService._();
  factory NavigationSessionService() => instance;

  NavigationSessionState _state = NavigationSessionState.uninitialized;
  String? _errorMessage;
  GoogleNavigationViewController? _viewController;
  StreamSubscription<OnArrivalEvent>? _arrivalSub;
  StreamSubscription<RoadSnappedLocationUpdatedEvent>? _locationSub;
  Timer? _guidancePollTimer;
  Timer? _tripPollTimer;
  StreamSubscription<RemainingTimeOrDistanceChangedEvent>? _remainingTripSub;
  StreamSubscription<NavInfoEvent>? _navInfoSub;
  final _stateController = StreamController<NavigationSessionState>.broadcast();
  final _tripController = StreamController<NavigationTripSnapshot>.broadcast();
  NavigationTripSnapshot _trip = const NavigationTripSnapshot();
  bool _sdkLocationReady = false;
  int _routeRequestGeneration = 0;
  bool _routeRequestInFlight = false;
  bool _lastRouteTimedOut = false;
  static const _routeTimeout = Duration(seconds: 45);

  NavigationSessionState get state => _state;
  String? get errorMessage => _errorMessage;
  Stream<NavigationSessionState> get stateChanges => _stateController.stream;
  Stream<NavigationTripSnapshot> get tripChanges => _tripController.stream;
  NavigationTripSnapshot get trip => _trip;
  bool get isInitialized => _state != NavigationSessionState.uninitialized &&
      _state != NavigationSessionState.initializing;

  void _setState(NavigationSessionState next, {String? error}) {
    _state = next;
    _errorMessage = error;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
    unawaited(_ensureNavigationChromeEnabled());
  }

  Future<bool> initialize() async {
    if (_state == NavigationSessionState.initializing ||
        isInitialized && _state != NavigationSessionState.error) {
      return _state != NavigationSessionState.error;
    }

    _setState(NavigationSessionState.initializing);

    try {
      if (!await GoogleMapsNavigator.areTermsAccepted()) {
        final accepted = await GoogleMapsNavigator.showTermsAndConditionsDialog(
          'Dominar Telemetry Navigation',
          'Dominar Telemetry',
        );
        if (!accepted) {
          _setState(
            NavigationSessionState.error,
            error: 'Navigation terms must be accepted to use turn-by-turn guidance.',
          );
          return false;
        }
      }

      if (await GoogleMapsNavigator.isInitialized()) {
        _setState(NavigationSessionState.browse);
        return true;
      }

      await GoogleMapsNavigator.initializeNavigationSession(
        taskRemovedBehavior: TaskRemovedBehavior.continueService,
      );

      _locationSub ??=
          await GoogleMapsNavigator.setRoadSnappedLocationUpdatedListener((event) {
        _sdkLocationReady = true;
      });

      _arrivalSub ??= GoogleMapsNavigator.setOnArrivalListener((event) async {
        await stopGuidance();
        await clearRoute();
      });

      await GoogleMapsNavigator.setAudioGuidance(
        NavigationAudioGuidanceSettings(
          guidanceType: NavigationAudioGuidanceType.alertsAndGuidance,
        ),
      );

      _setState(NavigationSessionState.browse);
      return true;
    } on SessionInitializationException catch (e) {
      final message = switch (e.code) {
        SessionInitializationError.termsNotAccepted =>
          'Accept Google Navigation terms to continue.',
        SessionInitializationError.locationPermissionMissing =>
          'Location permission is required for navigation.',
        SessionInitializationError.notAuthorized =>
          'API key is invalid or Navigation SDK for iOS is not enabled.',
      };
      _setState(NavigationSessionState.error, error: message);
      return false;
    } catch (e) {
      _setState(
        NavigationSessionState.error,
        error: 'Navigation session failed: $e',
      );
      return false;
    }
  }

  Future<void> attachViewController(GoogleNavigationViewController controller) async {
    _viewController = controller;
    await controller.setMyLocationEnabled(true);
    await controller.settings.setMyLocationButtonEnabled(false);
    await controller.setRecenterButtonEnabled(true);
    await _ensureNavigationChromeEnabled();
    unawaited(recenterMap());
  }

  /// Always enable Google Navigation SDK header / footer / progress (no Flutter overlays).
  Future<void> _ensureNavigationChromeEnabled() async {
    final controller = _viewController;
    if (controller == null) return;
    try {
      await controller.setNavigationHeaderEnabled(true);
      await controller.setNavigationFooterEnabled(true);
      await controller.setNavigationTripProgressBarEnabled(true);
      await controller.setRecenterButtonEnabled(true);
      final tripActive = _state == NavigationSessionState.routeReady ||
          _state == NavigationSessionState.navigating;
      if (tripActive) {
        await controller.setNavigationUIEnabled(true);
      }
      await controller.setPadding(EdgeInsets.zero);
      await _enableMapGestures();
    } catch (e) {
      debugPrint('[navigation] chrome enable failed: $e');
    }
  }

  void _emitTrip(NavigationTripSnapshot next) {
    _trip = next;
    if (!_tripController.isClosed) {
      _tripController.add(next);
    }
  }

  Future<void> _refreshTripFromSdk() async {
    if (_state != NavigationSessionState.routeReady &&
        _state != NavigationSessionState.navigating) {
      return;
    }
    try {
      final summary = await GoogleMapsNavigator.getCurrentTimeAndDistance();
      _emitTrip(
        _trip.copyWith(
          remainingTimeSeconds: summary.time.round(),
          remainingDistanceMeters: summary.distance.round(),
          guidanceActive: _state == NavigationSessionState.navigating,
        ),
      );
    } catch (e) {
      debugPrint('[navigation] trip refresh failed: $e');
    }
  }

  void _startTripInfoWatch() {
    _stopTripInfoWatch();
    _trip = const NavigationTripSnapshot();
    _emitTrip(_trip);

    _remainingTripSub =
        GoogleMapsNavigator.setOnRemainingTimeOrDistanceChangedListener((event) {
      _emitTrip(
        _trip.copyWith(
          remainingTimeSeconds: event.remainingTime.round(),
          remainingDistanceMeters: event.remainingDistance.round(),
        ),
      );
    });

    _navInfoSub = GoogleMapsNavigator.setNavInfoListener((event) {
      final info = event.navInfo;
      final step = info.currentStep;
      final guidanceActive = info.navState == NavState.enroute ||
          info.navState == NavState.rerouting;
      _emitTrip(
        _trip.copyWith(
          guidanceActive: guidanceActive,
          distanceToTurnMeters: info.distanceToCurrentStepMeters,
          turnInstruction: step?.fullInstructions,
          turnRoad: step?.simpleRoadName ?? step?.fullRoadName,
          remainingTimeSeconds:
              info.timeToFinalDestinationSeconds ?? _trip.remainingTimeSeconds,
          remainingDistanceMeters: info.distanceToFinalDestinationMeters ??
              _trip.remainingDistanceMeters,
        ),
      );
    });

    _tripPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_refreshTripFromSdk());
    });
    unawaited(_refreshTripFromSdk());
  }

  void _stopTripInfoWatch() {
    _tripPollTimer?.cancel();
    _tripPollTimer = null;
    unawaited(_remainingTripSub?.cancel());
    _remainingTripSub = null;
    unawaited(_navInfoSub?.cancel());
    _navInfoSub = null;
    _trip = const NavigationTripSnapshot();
    if (!_tripController.isClosed) {
      _tripController.add(_trip);
    }
  }

  Future<void> _enableMapGestures() async {
    final controller = _viewController;
    if (controller == null) return;
    try {
      await controller.settings.setScrollGesturesEnabled(true);
      await controller.settings.setZoomGesturesEnabled(true);
      await controller.settings.setTiltGesturesEnabled(true);
      await controller.settings.setRotateGesturesEnabled(true);
      await controller.settings.setScrollGesturesDuringRotateOrZoomEnabled(true);
    } catch (e) {
      debugPrint('[navigation] gesture enable failed: $e');
    }
  }

  Future<void> _presentRoutePreviewOnMap() async {
    final controller = _viewController;
    if (controller == null) return;
    // Route preview: native Google UI with alternate routes + Start — no guidance yet.
    await controller.setNavigationUIEnabled(true);
    await controller.setNavigationHeaderEnabled(true);
    await controller.setNavigationFooterEnabled(true);
    await controller.setNavigationTripProgressBarEnabled(true);
    await controller.setRecenterButtonEnabled(true);
    await controller.setPadding(EdgeInsets.zero);
    await controller.showRouteOverview();
    await _enableMapGestures();
    // Nav UI can re-lock the camera; overview must win so the rider can pick a route.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await controller.showRouteOverview();
    await _enableMapGestures();
  }

  /// Re-assert native chrome after layout changes (e.g. fullscreen toggle).
  Future<void> refreshNativeChrome() async {
    final controller = _viewController;
    if (controller == null) return;
    try {
      await controller.setNavigationUIEnabled(true);
      await controller.setNavigationHeaderEnabled(true);
      await controller.setNavigationFooterEnabled(true);
      await controller.setNavigationTripProgressBarEnabled(true);
      await controller.setRecenterButtonEnabled(true);
      await controller.setPadding(EdgeInsets.zero);
      if (_state == NavigationSessionState.navigating) {
        await controller.followMyLocation(CameraPerspective.tilted);
      } else if (_state == NavigationSessionState.routeReady) {
        await controller.showRouteOverview();
        await _enableMapGestures();
      }
    } catch (e) {
      debugPrint('[navigation] refreshNativeChrome failed: $e');
    }
  }

  /// Start turn-by-turn after the rider taps Google's Start (or we call this).
  Future<String?> beginGuidedNavigation() async {
    try {
      await refreshNativeChrome();
      if (!await GoogleMapsNavigator.isGuidanceRunning()) {
        await GoogleMapsNavigator.startGuidance();
      }
      await _viewController?.followMyLocation(CameraPerspective.tilted);
      _emitTrip(_trip.copyWith(guidanceActive: true));
      _setState(NavigationSessionState.navigating);
      _startGuidanceStateWatch();
      _startTripInfoWatch();
      return null;
    } catch (e) {
      final message = 'Could not start navigation: $e';
      _setState(NavigationSessionState.error, error: message);
      return message;
    }
  }

  /// Move the map to the user's location once GPS / road-snapped fix is ready.
  ///
  /// Uses [followMyLocation] only during active guidance. Route preview uses
  /// [showRouteOverview] so the map can be panned. Browse mode uses a one-shot
  /// [moveCamera] so the camera is not locked to GPS (which blocks panning).
  Future<void> recenterMap({double zoom = 15}) async {
    if (_viewController == null) return;
    if (!await _ensureSdkLocationReady()) return;
    try {
      switch (_state) {
        case NavigationSessionState.navigating:
          await _viewController!.followMyLocation(CameraPerspective.tilted);
        case NavigationSessionState.routeReady:
          await _viewController!.showRouteOverview();
          await _enableMapGestures();
        default:
          final location = await _viewController!.getMyLocation();
          if (location != null) {
            await _viewController!.moveCamera(
              CameraUpdate.newLatLngZoom(location, zoom),
            );
          }
      }
    } catch (e) {
      debugPrint('[navigation] recenterMap failed: $e');
    }
  }

  Future<bool> _ensureSdkLocationReady() async {
    if (_sdkLocationReady) return true;

    final mapLocation = await _viewController?.getMyLocation();
    if (mapLocation != null) {
      _sdkLocationReady = true;
      return true;
    }

    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      if (_sdkLocationReady) return true;
      final retryLocation = await _viewController?.getMyLocation();
      if (retryLocation != null) {
        _sdkLocationReady = true;
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return _sdkLocationReady;
  }

  Future<String?> setMotorbikeDestination({
    required LatLng target,
    required String title,
  }) async {
    if (_routeRequestInFlight) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    if (_routeRequestInFlight) {
      return 'Route calculation already in progress. Please wait.';
    }

    final requestGeneration = ++_routeRequestGeneration;
    _routeRequestInFlight = true;

    try {
      return await _setMotorbikeDestinationInternal(
        target: target,
        title: title,
        requestGeneration: requestGeneration,
      );
    } finally {
      if (requestGeneration == _routeRequestGeneration) {
        _routeRequestInFlight = false;
      }
    }
  }

  Future<String?> _setMotorbikeDestinationInternal({
    required LatLng target,
    required String title,
    required int requestGeneration,
  }) async {
    if (!await initialize()) {
      return _errorMessage ?? 'Navigation is not ready.';
    }

    if (_viewController == null) {
      return 'Map is still loading. Wait a moment and try again.';
    }

    if (!await _ensureSdkLocationReady()) {
      return 'Waiting for GPS fix (yellow circle). Go outdoors and wait for the blue dot, then try again.';
    }

    if (!await InternetReachability.canReachGoogle()) {
      return 'No internet for route calculation. Check Wi‑Fi or Cellular Data, then try again.';
    }

    if (requestGeneration != _routeRequestGeneration) {
      return null;
    }

    // Only clear an existing route; clearing on first pick resets the camera to 0,0.
    if (_state == NavigationSessionState.routeReady ||
        _state == NavigationSessionState.navigating) {
      try {
        if (await GoogleMapsNavigator.isGuidanceRunning()) {
          await GoogleMapsNavigator.stopGuidance();
        }
        await GoogleMapsNavigator.clearDestinations();
      } catch (_) {
        // Ignore cleanup errors from an empty session.
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }

    final travelModes = [
      NavigationTravelMode.driving,
      NavigationTravelMode.twoWheeler,
    ];

    NavigationRouteStatus? lastStatus;
    for (final travelMode in travelModes) {
      final destinations = Destinations(
        waypoints: [
          NavigationWaypoint.withLatLngTarget(title: title, target: target),
        ],
        displayOptions: NavigationDisplayOptions(showDestinationMarkers: true),
        routingOptions: RoutingOptions(
          travelMode: travelMode,
          alternateRoutesStrategy: NavigationAlternateRoutesStrategy.all,
        ),
      );

      final status = await _setDestinationsWithRetry(
        destinations,
        requestGeneration: requestGeneration,
      );

      if (requestGeneration != _routeRequestGeneration) {
        return null;
      }

      lastStatus = status;
      if (status == NavigationRouteStatus.statusOk) {
        // Preview only: show alternate routes + Google Start. Do not start guidance.
        await _presentRoutePreviewOnMap();
        _setState(NavigationSessionState.routeReady);
        _startGuidanceStateWatch();
        _startTripInfoWatch();
        return null;
      }

      if (status != NavigationRouteStatus.travelModeUnsupported &&
          status != NavigationRouteStatus.routeNotFound) {
        break;
      }
    }

    final message = _routeStatusMessage(
      lastStatus ?? NavigationRouteStatus.unknown,
    );
    if (message != null) {
      final detail = await _navigationDiagnosticsSuffix();
      await recenterMap();
      _setState(NavigationSessionState.browse);
      return '$message$detail';
    }
    return null;
  }

  Future<String> _navigationDiagnosticsSuffix() async {
    try {
      const channel = MethodChannel('com.dominar/maps');
      final raw = await channel.invokeMethod<Map<Object?, Object?>>(
        'getNavigationDiagnostics',
      );
      if (raw == null) return '';
      final bundleId = raw['bundleId'];
      final keyHint = raw['apiKeyHint'];
      final terms = raw['navigationTermsAccepted'];
      return '\n\nDiagnostics: bundle=$bundleId key=$keyHint navTerms=$terms';
    } catch (_) {
      return '';
    }
  }

  Future<NavigationRouteStatus> _setDestinationsWithRetry(
    Destinations destinations, {
    required int requestGeneration,
  }) async {
    const retryable = {
      NavigationRouteStatus.locationUnavailable,
      NavigationRouteStatus.locationUnknown,
      NavigationRouteStatus.statusCanceled,
    };

    NavigationRouteStatus status = NavigationRouteStatus.locationUnavailable;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (requestGeneration != _routeRequestGeneration) {
        return NavigationRouteStatus.statusCanceled;
      }

      try {
        _lastRouteTimedOut = false;
        status = await GoogleMapsNavigator.setDestinations(destinations).timeout(
          _routeTimeout,
          onTimeout: () {
            _lastRouteTimedOut = true;
            debugPrint('[navigation] setDestinations timed out after ${_routeTimeout.inSeconds}s');
            return NavigationRouteStatus.unknown;
          },
        );
        debugPrint('[navigation] setDestinations status=$status travelMode=${destinations.routingOptions?.travelMode}');
      } on SessionNotInitializedException {
        return NavigationRouteStatus.internalError;
      }

      if (status == NavigationRouteStatus.statusOk) {
        return status;
      }
      if (!retryable.contains(status)) {
        return status;
      }

      await _ensureSdkLocationReady();
      // Back off so a newer SDK request is not immediately canceled again.
      await Future.delayed(Duration(milliseconds: 600 + (attempt * 400)));
    }
    return status;
  }

  Future<String?> startGuidance() async {
    if (_state != NavigationSessionState.routeReady &&
        _state != NavigationSessionState.browse &&
        _state != NavigationSessionState.navigating) {
      return 'No route is ready to navigate.';
    }
    return beginGuidedNavigation();
  }

  Future<void> stopGuidance() async {
    try {
      if (await GoogleMapsNavigator.isGuidanceRunning()) {
        await GoogleMapsNavigator.stopGuidance();
      }
      if (_state == NavigationSessionState.navigating) {
        await _viewController?.setNavigationUIEnabled(true);
        await _viewController?.showRouteOverview();
      }
    } catch (_) {
      // Ignore cleanup errors.
    }
    if (_state == NavigationSessionState.navigating) {
      _setState(NavigationSessionState.routeReady);
    }
  }

  void _startGuidanceStateWatch() {
    _guidancePollTimer?.cancel();
    _guidancePollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_syncGuidanceState());
    });
  }

  void _stopGuidanceStateWatch() {
    _guidancePollTimer?.cancel();
    _guidancePollTimer = null;
  }

  Future<void> _syncGuidanceState() async {
    if (_state != NavigationSessionState.routeReady &&
        _state != NavigationSessionState.navigating) {
      return;
    }

    try {
      final running = await GoogleMapsNavigator.isGuidanceRunning();
      if (running && _state == NavigationSessionState.routeReady) {
        await _viewController?.followMyLocation(CameraPerspective.tilted);
        _emitTrip(_trip.copyWith(guidanceActive: true));
        _setState(NavigationSessionState.navigating);
      } else if (!running && _state == NavigationSessionState.navigating) {
        _emitTrip(_trip.copyWith(guidanceActive: false));
        _setState(NavigationSessionState.routeReady);
      }
    } catch (_) {
      // Ignore polling errors.
    }
  }

  Future<void> clearRoute() async {
    _routeRequestGeneration++;
    _stopGuidanceStateWatch();
    _stopTripInfoWatch();
    await stopGuidance();
    try {
      await GoogleMapsNavigator.clearDestinations();
    } catch (_) {
      // Ignore cleanup errors.
    }
    // Delay disabling nav UI so the SDK can finish clearing the route polyline.
    final controller = _viewController;
    if (controller != null) {
      unawaited(Future.delayed(const Duration(milliseconds: 500), () async {
        try {
          await controller.setNavigationUIEnabled(false);
          await controller.setPadding(EdgeInsets.zero);
        } catch (_) {}
      }));
    }
    _setState(NavigationSessionState.browse);
  }

  Future<void> recenter() async {
    await recenterMap();
  }

  String? _routeStatusMessage(NavigationRouteStatus status) {
    if (_lastRouteTimedOut && status == NavigationRouteStatus.unknown) {
      return 'Route calculation timed out. Wait for a GPS fix (blue dot, not yellow circle), '
          'enable Precise Location for this app, then try again.';
    }
    return switch (status) {
      NavigationRouteStatus.statusOk => null,
      NavigationRouteStatus.routeNotFound => 'No route found to that destination.',
      NavigationRouteStatus.networkError =>
        'Network error ($status). Confirm billing is enabled and Navigation SDK is enabled '
            'in Google Cloud (APIs & Services → Library → Navigation SDK). '
            'Key must allow iOS bundle com.hitesh.dominarTelemetry.',
      NavigationRouteStatus.locationUnavailable =>
        'GPS not ready (yellow circle). Enable Precise Location and wait for the blue dot.',
      NavigationRouteStatus.locationUnknown =>
        'Location unknown. Settings → Dominar Telemetry → Location → While Using the App.',
      NavigationRouteStatus.apiKeyNotAuthorized =>
        'API key rejected for Navigation SDK ($status). Enable Navigation SDK + Maps SDK for iOS, '
            'link billing, and set iOS app restriction to com.hitesh.dominarTelemetry.',
      NavigationRouteStatus.travelModeUnsupported =>
        'Motorbike routing not supported here; driving mode also failed.',
      NavigationRouteStatus.quotaExceeded =>
        'Navigation quota exceeded. Check Google Cloud billing.',
      NavigationRouteStatus.quotaCheckFailed =>
        'Navigation billing check failed. Link a billing account in Google Cloud.',
      NavigationRouteStatus.internalError =>
        'Navigation SDK internal error ($status). Restart the app.',
      NavigationRouteStatus.statusCanceled =>
        'Route calculation was interrupted. Try again.',
      _ => 'Could not calculate route ($status).',
    };
  }

  Future<void> dispose() async {
    _stopGuidanceStateWatch();
    await _arrivalSub?.cancel();
    _arrivalSub = null;
    await _locationSub?.cancel();
    _locationSub = null;
    try {
      await GoogleMapsNavigator.cleanup();
    } catch (_) {
      // Session may already be cleaned up.
    }
    await _stateController.close();
    await _tripController.close();
    _viewController = null;
    _setState(NavigationSessionState.uninitialized);
  }
}
