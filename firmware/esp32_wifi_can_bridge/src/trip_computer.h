#pragma once

#include <Preferences.h>

#include "can_types.h"
#include "d400_config.h"

extern Preferences gOdometerPrefs;
extern bool gOdometerPrefsReady;

extern TripState gTrips[D400_TRIP_COUNT];

void setupOdometer();
void setupTrips();
void maintainOdometer();
void maintainTripComputer();
void resetTrip(uint8_t index);
bool saveTrip(uint8_t index, bool force);

float odometerKm();
float tripDistanceKm(const TripState& trip);
float tripKmpl(const TripState& trip);

uint32_t odometerMetersValue();
uint32_t odometerSaveCountValue();
