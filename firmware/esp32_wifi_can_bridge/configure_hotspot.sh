#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$ROOT/src/wifi_credentials.h"

read -r -p "Primary iPhone hotspot name: " primary_ssid
read -r -s -p "Primary Personal Hotspot password: " primary_password
printf "\n"

if [[ -z "$primary_ssid" ]]; then
  echo "Primary hotspot name cannot be empty."
  exit 1
fi

if (( ${#primary_password} < 8 )); then
  echo "The primary hotspot password must contain at least 8 characters."
  exit 1
fi

read -r -p "Secondary iPhone hotspot name (leave blank to skip): " secondary_ssid
secondary_password=""
if [[ -n "$secondary_ssid" ]]; then
  read -r -s -p "Secondary Personal Hotspot password: " secondary_password
  printf "\n"
  if (( ${#secondary_password} < 8 )); then
    echo "The secondary hotspot password must contain at least 8 characters."
    exit 1
  fi
fi

escape_cpp_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf "%s" "$value"
}

escaped_primary_ssid="$(escape_cpp_string "$primary_ssid")"
escaped_primary_password="$(escape_cpp_string "$primary_password")"
escaped_secondary_ssid="$(escape_cpp_string "$secondary_ssid")"
escaped_secondary_password="$(escape_cpp_string "$secondary_password")"

cat > "$OUTPUT" <<EOF
#pragma once

// Generated locally by configure_hotspot.sh. This file is git-ignored.
#define D400_HOTSPOT_SSID "$escaped_primary_ssid"
#define D400_HOTSPOT_PASSWORD "$escaped_primary_password"
#define D400_HOTSPOT2_SSID "$escaped_secondary_ssid"
#define D400_HOTSPOT2_PASSWORD "$escaped_secondary_password"
EOF

chmod 600 "$OUTPUT"
if [[ -n "$secondary_ssid" ]]; then
  echo "Saved two hotspot networks to src/wifi_credentials.h"
else
  echo "Saved one hotspot network to src/wifi_credentials.h"
fi
