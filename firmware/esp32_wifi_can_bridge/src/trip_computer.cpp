#include "trip_computer.h"

#include "passive_decode.h"

Preferences gOdometerPrefs;
bool gOdometerPrefsReady = false;
TripState gTrips[D400_TRIP_COUNT];

static bool odometerWasMoving = false;
static uint32_t odometerMeters = D400_ODOMETER_INITIAL_METERS;
static uint32_t odometerLastSavedMeters = D400_ODOMETER_INITIAL_METERS;
static uint32_t odometerLastUpdateMs = 0;
static uint32_t odometerLastSaveMs = 0;
static uint32_t odometerSaveCount = 0;
static float odometerFractionMeters = 0.0f;

static uint32_t tripLastTickMs = 0;
static uint32_t tripLastSaveMs = 0;
static bool tripWasActive = false;

static const char* TRIP_DISTANCE_PREF_KEYS[D400_TRIP_COUNT] = {"t1_dist_m", "t2_dist_m"};
static const char* TRIP_FUEL_PREF_KEYS[D400_TRIP_COUNT] = {"t1_fuel_ml", "t2_fuel_ml"};
static const char* TRIP_SECONDS_PREF_KEYS[D400_TRIP_COUNT] = {"t1_sec", "t2_sec"};

static float tripFuelLiters(const TripState& trip) {
  return (static_cast<float>(trip.fuelMilliLiters) + trip.fuelFractionMilliLiters) / 1000.0f;
}

float tripDistanceKm(const TripState& trip) {
  return (static_cast<float>(trip.distanceMeters) + trip.distanceFractionMeters) / 1000.0f;
}

float tripKmpl(const TripState& trip) {
  float fuelLiters = tripFuelLiters(trip);
  if (fuelLiters <= 0.0001f) return 0.0f;
  return tripDistanceKm(trip) / fuelLiters;
}

float odometerKm() {
  return (static_cast<float>(odometerMeters) + odometerFractionMeters) / 1000.0f;
}

uint32_t odometerMetersValue() {
  return odometerMeters;
}

uint32_t odometerSaveCountValue() {
  return odometerSaveCount;
}

static uint32_t odometerUnsavedMeters() {
  return odometerMeters >= odometerLastSavedMeters ? odometerMeters - odometerLastSavedMeters : 0;
}

static bool saveOdometer(bool force) {
  if (!gOdometerPrefsReady) return false;
  uint32_t unsavedMeters = odometerUnsavedMeters();
  if (!force && unsavedMeters == 0) return true;

  size_t written = gOdometerPrefs.putUInt(D400_ODOMETER_PREF_METERS_KEY, odometerMeters);
  if (written == sizeof(uint32_t)) {
    odometerLastSavedMeters = odometerMeters;
    odometerLastSaveMs = millis();
    odometerSaveCount++;
    return true;
  }
  return false;
}

static void maybeSaveOdometer(uint32_t now) {
  uint32_t unsavedMeters = odometerUnsavedMeters();
  if (unsavedMeters == 0) return;
  if (unsavedMeters >= D400_ODOMETER_SAVE_DISTANCE_METERS ||
      now - odometerLastSaveMs >= D400_ODOMETER_SAVE_INTERVAL_MS) {
    saveOdometer(false);
  }
}

void setupOdometer() {
  gOdometerPrefsReady = gOdometerPrefs.begin(D400_PREF_NAMESPACE, false);
  if (!gOdometerPrefsReady) return;

  bool hadStoredValue = gOdometerPrefs.isKey(D400_ODOMETER_PREF_METERS_KEY);
  uint32_t storedMeters = hadStoredValue
                              ? gOdometerPrefs.getUInt(D400_ODOMETER_PREF_METERS_KEY,
                                                       D400_ODOMETER_INITIAL_METERS)
                              : D400_ODOMETER_INITIAL_METERS;
  odometerMeters = storedMeters < D400_ODOMETER_INITIAL_METERS
                       ? D400_ODOMETER_INITIAL_METERS
                       : storedMeters;
  odometerLastSavedMeters = odometerMeters;
  odometerLastSaveMs = millis();
  odometerFractionMeters = 0.0f;

  if (!hadStoredValue || odometerMeters != storedMeters) {
    saveOdometer(true);
  }
}

void setupTrips() {
  tripLastTickMs = millis();
  tripLastSaveMs = millis();
  if (!gOdometerPrefsReady) return;

  bool initializedAny = false;
  for (uint8_t i = 0; i < D400_TRIP_COUNT; i++) {
    TripState& trip = gTrips[i];
    bool hadStoredValue = gOdometerPrefs.isKey(TRIP_DISTANCE_PREF_KEYS[i]) ||
                          gOdometerPrefs.isKey(TRIP_FUEL_PREF_KEYS[i]) ||
                          gOdometerPrefs.isKey(TRIP_SECONDS_PREF_KEYS[i]);
    trip.distanceMeters = gOdometerPrefs.getUInt(TRIP_DISTANCE_PREF_KEYS[i], 0);
    trip.fuelMilliLiters = gOdometerPrefs.getUInt(TRIP_FUEL_PREF_KEYS[i], 0);
    trip.seconds = gOdometerPrefs.getUInt(TRIP_SECONDS_PREF_KEYS[i], 0);
    trip.savedDistanceMeters = trip.distanceMeters;
    trip.savedFuelMilliLiters = trip.fuelMilliLiters;
    trip.savedSeconds = trip.seconds;
    trip.distanceFractionMeters = 0.0f;
    trip.fuelFractionMilliLiters = 0.0f;
    if (!hadStoredValue) initializedAny = true;
  }

  if (initializedAny) {
    for (uint8_t i = 0; i < D400_TRIP_COUNT; i++) {
      saveTrip(i, true);
    }
  }
}

void maintainOdometer() {
  uint32_t now = millis();
  bool speedFresh = passiveSpeedFresh(now);
  float speedKph = speedFresh ? distanceSpeedKph(constrain(gTelemetry.speed, 0.0f, 299.0f)) : 0.0f;
  bool moving = speedFresh && speedKph >= D400_ODOMETER_MIN_SPEED_KPH;

  if (!moving) {
    if (odometerWasMoving) saveOdometer(true);
    odometerWasMoving = false;
    odometerLastUpdateMs = now;
    return;
  }

  if (odometerLastUpdateMs == 0) {
    odometerLastUpdateMs = now;
    odometerWasMoving = true;
    return;
  }

  uint32_t dtMs = now - odometerLastUpdateMs;
  odometerLastUpdateMs = now;
  odometerWasMoving = true;

  if (dtMs == 0 || dtMs > D400_ODOMETER_MAX_INTEGRATION_GAP_MS) return;

  odometerFractionMeters += speedKph * static_cast<float>(dtMs) / 3600.0f;
  if (odometerFractionMeters >= 1.0f) {
    uint32_t wholeMeters = static_cast<uint32_t>(odometerFractionMeters);
    odometerMeters += wholeMeters;
    odometerFractionMeters -= static_cast<float>(wholeMeters);
  }

  maybeSaveOdometer(now);
}

static bool tripDirty(uint8_t index) {
  if (index >= D400_TRIP_COUNT) return false;
  const TripState& trip = gTrips[index];
  return trip.distanceMeters != trip.savedDistanceMeters ||
         trip.fuelMilliLiters != trip.savedFuelMilliLiters ||
         trip.seconds != trip.savedSeconds;
}

static uint32_t tripUnsavedMeters(uint8_t index) {
  if (index >= D400_TRIP_COUNT) return 0;
  const TripState& trip = gTrips[index];
  return trip.distanceMeters >= trip.savedDistanceMeters
             ? trip.distanceMeters - trip.savedDistanceMeters
             : 0;
}

bool saveTrip(uint8_t index, bool force) {
  if (index >= D400_TRIP_COUNT) return false;
  if (!gOdometerPrefsReady) return false;
  if (!force && !tripDirty(index)) return true;

  TripState& trip = gTrips[index];
  size_t distanceWritten = gOdometerPrefs.putUInt(TRIP_DISTANCE_PREF_KEYS[index], trip.distanceMeters);
  size_t fuelWritten = gOdometerPrefs.putUInt(TRIP_FUEL_PREF_KEYS[index], trip.fuelMilliLiters);
  size_t secondsWritten = gOdometerPrefs.putUInt(TRIP_SECONDS_PREF_KEYS[index], trip.seconds);
  if (distanceWritten == sizeof(uint32_t) && fuelWritten == sizeof(uint32_t) &&
      secondsWritten == sizeof(uint32_t)) {
    trip.savedDistanceMeters = trip.distanceMeters;
    trip.savedFuelMilliLiters = trip.fuelMilliLiters;
    trip.savedSeconds = trip.seconds;
    trip.saveCount++;
    tripLastSaveMs = millis();
    return true;
  }
  return false;
}

static bool saveAllTrips(bool force) {
  bool ok = true;
  for (uint8_t i = 0; i < D400_TRIP_COUNT; i++) {
    ok = saveTrip(i, force) && ok;
  }
  return ok;
}

static void maybeSaveTrips(uint32_t now) {
  bool anyDirty = false;
  bool distanceThresholdReached = false;
  for (uint8_t i = 0; i < D400_TRIP_COUNT; i++) {
    if (!tripDirty(i)) continue;
    anyDirty = true;
    if (tripUnsavedMeters(i) >= D400_TRIP_SAVE_DISTANCE_METERS) {
      distanceThresholdReached = true;
    }
  }
  if (!anyDirty) return;
  if (distanceThresholdReached || now - tripLastSaveMs >= D400_TRIP_SAVE_INTERVAL_MS) {
    saveAllTrips(false);
  }
}

void resetTrip(uint8_t index) {
  if (index >= D400_TRIP_COUNT) return;
  TripState& trip = gTrips[index];
  trip.distanceMeters = 0;
  trip.fuelMilliLiters = 0;
  trip.seconds = 0;
  trip.distanceFractionMeters = 0.0f;
  trip.fuelFractionMilliLiters = 0.0f;
}

static float estimateFuelRateLph(uint32_t now) {
  if (!passiveRpmFresh(now) || !passiveSensorFresh(now)) return 0.0f;

  float rpm = constrain(gTelemetry.rpm, 0.0f, 14000.0f);
  if (rpm <= D400_TRIP_ENGINE_RUNNING_RPM) return 0.0f;

  float mapKpa = constrain(gTelemetry.map, 5.0f, 120.0f);
  float iatKelvin = gTelemetry.iat + 273.15f;
  if (iatKelvin < 230.0f) iatKelvin = 230.0f;
  float tpsPct = constrain(gTelemetry.tps, 0.0f, 100.0f);

  float mapPascal = mapKpa * 1000.0f;
  float airDensity = mapPascal / (D400_TRIP_GAS_CONSTANT_R * iatKelvin);
  float volumeFlowPerSec = (rpm / 60.0f) / 2.0f * D400_TRIP_DISPLACEMENT_M3;
  float volumetricEfficiency = D400_TRIP_VE_BASE + (tpsPct / 100.0f) * D400_TRIP_VE_TPS_SCALE;
  float airMassFlowGps = volumeFlowPerSec * airDensity * volumetricEfficiency * 1000.0f;
  float fuelMassFlowGps = airMassFlowGps / D400_TRIP_STOICH_AFR;
  return (fuelMassFlowGps * 3600.0f) / D400_TRIP_FUEL_DENSITY_G_L;
}

static void accumulateTripTick(uint32_t now) {
  (void)now;
  bool engineRunning =
      passiveRpmFresh(now) && !isnan(gTelemetry.rpm) && gTelemetry.rpm > D400_TRIP_ENGINE_RUNNING_RPM;
  float speedKph = 0.0f;
  if (passiveSpeedFresh(now)) {
    speedKph = distanceSpeedKph(constrain(gTelemetry.speed, 0.0f, 299.0f));
    if (speedKph < D400_ODOMETER_MIN_SPEED_KPH) speedKph = 0.0f;
  }

  float distanceMetersThisSecond = speedKph / 3.6f;
  float fuelMilliLitersThisSecond = estimateFuelRateLph(now) / 3.6f;

  for (uint8_t i = 0; i < D400_TRIP_COUNT; i++) {
    TripState& trip = gTrips[i];
    if (engineRunning && trip.seconds < UINT32_MAX) trip.seconds++;

    trip.distanceFractionMeters += distanceMetersThisSecond;
    if (trip.distanceFractionMeters >= 1.0f) {
      uint32_t wholeMeters = static_cast<uint32_t>(trip.distanceFractionMeters);
      trip.distanceMeters += wholeMeters;
      trip.distanceFractionMeters -= static_cast<float>(wholeMeters);
    }

    trip.fuelFractionMilliLiters += fuelMilliLitersThisSecond;
    if (trip.fuelFractionMilliLiters >= 1.0f) {
      uint32_t wholeMilliLiters = static_cast<uint32_t>(trip.fuelFractionMilliLiters);
      trip.fuelMilliLiters += wholeMilliLiters;
      trip.fuelFractionMilliLiters -= static_cast<float>(wholeMilliLiters);
    }
  }
}

void maintainTripComputer() {
  uint32_t now = millis();
  bool engineRunning =
      passiveRpmFresh(now) && !isnan(gTelemetry.rpm) && gTelemetry.rpm > D400_TRIP_ENGINE_RUNNING_RPM;

  if (tripLastTickMs == 0) {
    tripLastTickMs = now;
    tripLastSaveMs = now;
    tripWasActive = engineRunning;
    return;
  }

  uint32_t elapsedMs = now - tripLastTickMs;
  if (elapsedMs >= D400_TRIP_TICK_MS) {
    uint32_t ticks = elapsedMs / D400_TRIP_TICK_MS;
    if (ticks > 2) ticks = 1;
    for (uint32_t tick = 0; tick < ticks; tick++) {
      accumulateTripTick(now);
    }
    tripLastTickMs = (ticks > 2) ? now : tripLastTickMs + ticks * D400_TRIP_TICK_MS;
  }

  if (!engineRunning && tripWasActive) saveAllTrips(true);
  tripWasActive = engineRunning;
  maybeSaveTrips(now);
}
