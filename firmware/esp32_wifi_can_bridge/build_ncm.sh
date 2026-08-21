#!/usr/bin/env bash
# ESP-IDF refuses project paths that contain a space. This folder name includes
# " Cursor", so NCM firmware is compiled from a copy under /tmp.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_NAME="${1:-d400-ncm-bench}"
DEST=/tmp/d400-fw
mkdir -p "$DEST"
rsync -a --delete \
  --exclude '.pio' \
  --exclude 'sdkconfig' \
  --exclude 'sdkconfig.old' \
  --exclude 'sdkconfig.*-bench' \
  --exclude 'sdkconfig.*-ncm' \
  --exclude 'managed_components' \
  --exclude 'dependencies.lock' \
  "$ROOT/" "$DEST/"
cd "$DEST"
rm -f sdkconfig sdkconfig.old sdkconfig.d400-*
pio run -e "$ENV_NAME"
echo "Build OK. Firmware: $DEST/.pio/build/$ENV_NAME/firmware.bin"
echo "Flash later with the ESP32 plugged in:"
echo "  cd $DEST && pio run -e $ENV_NAME -t upload"
