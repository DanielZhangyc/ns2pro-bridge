# Third-party notices

The project code is MIT licensed. The complete MIT grant and disclaimer are in
[LICENSE](LICENSE) and included in packaged apps.

- NS2 transport and dual-band codec extracted from
  [smbw-mobile](https://github.com/DanielZhangyc/smbw-mobile), commit
  `56737aacd5554ff6d38c97c70bbe89279fc4d1a6`.
  Original project copyright 2026 jhaizhou; subsequent adaptation by DanielZhangyc.
  No game data, game modules, keys, shaders, or saves are included.
- Xbox BLE report descriptor/layout adapted from
  [WaveBird](https://github.com/murphyjt/wavebird/blob/b04a072f1b17df58965efb14a066873a0b48da2a/WaveBird/HID/XboxSeriesOutputProfile.swift),
  MIT, copyright 2026 Joshua Murphy. Its full MIT notice also appears in XboxReports.swift.
  BLE initialization/calibration research also consulted WaveBird.
- BLE protocol/calibration references include
  [procon2-mac](https://github.com/caqlayan/procon2-mac), MIT,
  copyright 2026 Arda Caglayan Ercan. The transport preserves this notice.
- Protocol research reference:
  [switch2_controller_research](https://github.com/ndeadly/switch2_controller_research).
  Xbox rumble mask/timing facts were cross-checked with xpadneo and SDL;
  their implementation code was not copied.
  Motion/accessory regression vectors quote two captured BLE notifications;
  capture filenames and frame numbers are recorded in MotionAccessoryTests.swift.
- The local DSU interface independently implements the
  [Cemuhook protocol description](https://github.com/v1993/cemuhook-protocol).
  Sensor-axis rotation was cross-checked with the
  [SDL Switch 2 driver](https://github.com/libsdl-org/SDL/blob/8a1684fbbc8b04c94cdf6b304450c5d941d0cafb/src/joystick/hidapi/SDL_hidapi_switch2.c);
  its implementation code was not copied.
- App icon controller outline adapted from Lucide `gamepad-2`, ISC licensed.
  The editable Apple Icon Composer project and full attribution are in
  [Resources/IconSources/ATTRIBUTION.md](Resources/IconSources/ATTRIBUTION.md).
- The controller photograph, `Resources/Controller/ns2-pro-front.png`, is an
  unmodified Nintendo product image, copyright Nintendo. It is **not covered by
  this project's MIT license**. Its official source, download details and rights
  notice are in [Resources/Controller/ATTRIBUTION.md](Resources/Controller/ATTRIBUTION.md).
  Public availability does not grant an open-content license or imply endorsement.

Nintendo, Switch, Xbox and Microsoft are trademarks of their respective owners.
The virtual device uses Xbox-compatible identifiers for host driver recognition;
this project is independent of Nintendo and Microsoft.
