#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
configuration="${CONFIGURATION:-Debug}"
platform="${IOS_PLATFORM:-simulator}"
if [[ "$platform" == "device" ]]; then
  if [[ -n "${IOS_DEVICE_ID:-}" ]]; then
    destination="id=$IOS_DEVICE_ID"
  else
    destination="generic/platform=iOS"
  fi
  derived="$project_dir/.build/ios"
else
  destination="generic/platform=iOS Simulator"
  derived="$project_dir/.build/ios-simulator"
fi
arguments=(-project Apps/iOS/BilibiliNEXT.xcodeproj -scheme BilibiliNEXT -configuration "$configuration" -destination "$destination" -derivedDataPath "$derived")
if [[ -n "${DEVELOPMENT_TEAM:-}" && "$platform" == "device" ]]; then
  arguments+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
else
  arguments+=(CODE_SIGNING_ALLOWED=NO)
fi
xcodebuild "${arguments[@]}" build
