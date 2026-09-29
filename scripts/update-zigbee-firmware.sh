#!/usr/bin/env bash
#
# Generates drivers/<id>/driver.firmware.compose.json and drivers/<id>/assets/firmware/*
# from the Koenkk/zigbee-OTA repository, following
# https://apps.developer.homey.app/wireless/zigbee/zigbee-firmware-updates
#
# The Hue images in zigbee-OTA carry no modelId, only manufacturerCode + imageType, so
# which images belong to which driver comes from scripts/zigbee-firmware-map.json:
#
#   {
#     "drivers": { "SML001": ["0x010D"], "LOM002": { "imageTypes": [277, 282], "latestOnly": false } },
#     "rules": [
#       { "name": "Bulbs", "pattern": "^(LCA|LTA)", "imageTypes": ["0x0114"] },
#       { "name": "Other lights", "template": "^light_", "imageTypes": ["0x0114"] }
#     ]
#   }
#
# An entry in "drivers" wins; otherwise the first rule whose "pattern" matches the driver id and
# whose "template" matches one of its $extends templates applies. New drivers are therefore
# picked up automatically. An empty imageTypes list means no firmware.
#
# By default only the newest file per imageType is included, so every run replaces older
# firmware with the newest release. Devices whose current firmware is below that file's
# minFileVersion get no update; set "latestOnly": false to include every version (Hue firmware
# is often an upgrade chain). Firmware previously generated for unmatched drivers is removed.
#
# Hue imageTypes in zigbee-OTA that are missing from the map's "imageTypes" table are reported,
# so new hardware platforms can be added to a rule.
#
# Usage: scripts/update-zigbee-firmware.sh [--ota-dir <local zigbee-OTA clone>] [--map <file>] [--dry-run]
#
# Requires: bash, curl, jq, shasum or sha512sum.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVERS_DIR="$ROOT/drivers"
MAP_FILE="$ROOT/scripts/zigbee-firmware-map.json"
OTA_RAW_BASE="https://raw.githubusercontent.com/Koenkk/zigbee-OTA/master"
MANUFACTURER_CODE=4107 # Signify / Philips
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zigbee-ota-homey"
SLEEPY_CLASSES="remote sensor"

OTA_DIR=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --ota-dir) OTA_DIR="$2"; shift 2 ;;
    --map) MAP_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done

sha512() {
  if command -v sha512sum >/dev/null; then sha512sum "$1" | cut -d' ' -f1
  else shasum -a 512 "$1" | cut -d' ' -f1
  fi
}

[ -f "$MAP_FILE" ] || { echo "Mapping file not found: $MAP_FILE" >&2; exit 1; }

mkdir -p "$CACHE_DIR"
INDEX="$CACHE_DIR/index.json"

if [ -n "$OTA_DIR" ]; then
  cp "$OTA_DIR/index.json" "$INDEX"
else
  echo "Downloading zigbee-OTA index.json"
  curl -fsSL "$OTA_RAW_BASE/index.json" -o "$INDEX"
fi

HEX_DEF='def hex: ascii_downcase | ltrimstr("0x") | explode
  | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
def tohex: . as $n | "0x" + ([3, 2, 1, 0] | map(($n / pow(16; .) | floor) % 16 | "0123456789ABCDEF"[.:. + 1]) | join(""));'

# Normalise every driver entry and rule to { types: [numbers], latestOnly: bool, ... }.
NORMALISED_MAP="$(jq "$HEX_DEF"'
  def norm: (if type == "array" then { imageTypes: . } else . end)
    | . + { types: (.imageTypes | map(if type == "string" then hex else . end)),
            latestOnly: (if has("latestOnly") then .latestOnly else true end) };
  { drivers: ((.drivers // {}) | map_values(norm)), rules: ((.rules // []) | map(norm)) }
' "$MAP_FILE")"

# Fetches an image into the cache (or local clone) and prints its local path.
fetch_image() {
  local url="$1" expected_sha="$2" rel file
  rel="${url#"$OTA_RAW_BASE/"}"
  if [ -n "$OTA_DIR" ] && [ -f "$OTA_DIR/$rel" ]; then
    file="$OTA_DIR/$rel"
  else
    file="$CACHE_DIR/$rel"
    if [ ! -f "$file" ] || [ "$(sha512 "$file")" != "$expected_sha" ]; then
      mkdir -p "$(dirname "$file")"
      curl -fsSL "$url" -o "$file"
    fi
  fi
  if [ "$(sha512 "$file")" != "$expected_sha" ]; then
    echo "Checksum mismatch for $url" >&2
    exit 1
  fi
  echo "$file"
}

# Prints the mapping for a driver as JSON with a "source" label, or nothing when unmatched.
resolve_mapping() {
  jq -c --arg d "$1" --slurpfile compose "$2" '
    ($compose[0]["$extends"] // [] | if type == "array" then . else [.] end) as $templates
    | if .drivers | has($d) then .drivers[$d] + { source: "driver entry" }
      else first(.rules[]
          | select((.pattern as $p | $p == null or ($d | test($p)))
              and (.template as $t | $t == null or ($templates | any(test($t))))))
        | . + { source: ("rule: " + (.name // .pattern // .template)) }
      end
  ' <<<"$NORMALISED_MAP"
}

total_bytes=0
generated=0
unmapped=()
excluded=()

for driver_path in "$DRIVERS_DIR"/*/; do
  driver="$(basename "$driver_path")"
  compose="$driver_path/driver.compose.json"
  firmware_compose="$driver_path/driver.firmware.compose.json"
  firmware_dir="$driver_path/assets/firmware"
  [ -f "$compose" ] || continue

  mapping="$(resolve_mapping "$driver" "$compose")"

  # This script owns the firmware files: always start from a clean slate.
  if [ "$DRY_RUN" -eq 0 ]; then
    rm -rf "$firmware_dir" "$firmware_compose"
  fi

  if [ -z "$mapping" ]; then
    unmapped+=("$driver")
    continue
  fi
  if [ "$(jq '.types | length' <<<"$mapping")" -eq 0 ]; then
    excluded+=("$driver ($(jq -r .source <<<"$mapping"))")
    continue
  fi

  types="$(jq -c '.types' <<<"$mapping")"
  entries="$(jq -c --argjson m "$mapping" --argjson mc "$MANUFACTURER_CODE" '
    [.[] | select(.manufacturerCode == $mc and (.imageType as $t | $m.types | index($t)))]
    | if $m.latestOnly then group_by(.imageType) | map(max_by(.fileVersion)) else . end
    | sort_by(.imageType, .fileVersion)
  ' "$INDEX")"

  count="$(jq length <<<"$entries")"
  if [ "$count" -eq 0 ]; then
    echo "  $driver: no images in zigbee-OTA for imageType(s) $types" >&2
    continue
  fi

  [ "$DRY_RUN" -eq 0 ] && mkdir -p "$firmware_dir"

  while IFS=$'\t' read -r url sha name size; do
    total_bytes=$((total_bytes + size))
    [ "$DRY_RUN" -eq 1 ] && continue
    src="$(fetch_image "$url" "$sha")"
    cp "$src" "$firmware_dir/$name"
  done < <(jq -r '.[] | [.url, .sha512, .fileName, .fileSize] | @tsv' <<<"$entries")

  if [ "$DRY_RUN" -eq 0 ]; then
    jq -n \
      --argjson entries "$entries" \
      --argjson compose "$(cat "$compose")" \
      --arg sleepy "$SLEEPY_CLASSES" '
      ($compose.zigbee.manufacturerName | if type == "array" then . else [.] end) as $manufacturers
      | ($compose.zigbee.productId | if type == "array" then . else [.] end) as $productIds
      | [$entries[] | {
          fileVersion,
          imageType,
          manufacturerCode,
          size: .fileSize,
          name: .fileName,
          integrity: ("sha512:" + .sha512)
        }
        + (if .minFileVersion != null then { minFileVersion } else {} end)
        + (if .maxFileVersion != null then { maxFileVersion } else {} end)
        + (if .hardwareVersionMin != null then { minHardwareVersion: .hardwareVersionMin } else {} end)
        + (if .hardwareVersionMax != null then { maxHardwareVersion: .hardwareVersionMax } else {} end)
      ] as $files
      | (if ($sleepy | split(" ") | index($compose.class)) then {
          wakeInstruction: {
            en: "Press a button on the device, or trigger its sensor, to wake it up.",
            nl: "Druk op een knop van het apparaat, of activeer de sensor, om het wakker te maken."
          }
        } else {} end)
      + {
          updates: [$manufacturers[] | {
            changelog: {
              en: "Firmware update from the Philips Hue OTA server.",
              nl: "Firmware-update van de Philips Hue OTA-server."
            },
            device: { manufacturerName: ., productId: $productIds },
            files: $files
          }]
        }
    ' > "$firmware_compose"
  fi

  echo "  $driver: $count image(s), $(jq -r "$HEX_DEF"'(.types | map(tohex) | join(",")) + " [" + .source + "]"' <<<"$mapping")"
  generated=$((generated + 1))
done

echo
echo "Drivers with firmware: $generated"
echo "Total firmware size:   $((total_bytes / 1024)) KiB"
[ "$DRY_RUN" -eq 1 ] && echo "(dry run, nothing written)"
if [ "${#excluded[@]}" -gt 0 ]; then
  echo "Drivers excluded by the map (${#excluded[@]}):"
  printf '  %s\n' "${excluded[@]}"
fi
if [ "${#unmapped[@]}" -gt 0 ]; then
  echo "Drivers without a matching entry or rule in $(basename "$MAP_FILE") (${#unmapped[@]}):"
  printf '  %s\n' "${unmapped[@]}"
fi

# Report Hue hardware platforms that zigbee-OTA knows about but the map does not.
new_types="$(jq -r --slurpfile map "$MAP_FILE" --argjson mc "$MANUFACTURER_CODE" "$HEX_DEF"'
  ($map[0].imageTypes // {} | keys | map(hex)) as $known
  | [.[] | select(.manufacturerCode == $mc and (.imageType as $t | $known | index($t) | not))]
  | group_by(.imageType)[]
  | "  \(.[0].imageType | tohex): \(max_by(.fileVersion).fileName)"
' "$INDEX")"
if [ -n "$new_types" ]; then
  echo "New Hue imageTypes in zigbee-OTA, not yet in the map (add them to \"imageTypes\" and a rule):"
  echo "$new_types"
fi
