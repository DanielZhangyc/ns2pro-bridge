# NS2 Pro Bridge

[简体中文](README.zh-CN.md)

A standalone Nintendo Switch 2 Pro Bluetooth adapter for macOS, providing virtual Xbox controller input, ordinary rumble, a local dual-band haptics interface and experimental DSU motion output.

The interface supports English and Simplified Chinese and follows macOS language preferences, with English as the default.

## Technical details

```mermaid
flowchart LR
    Controller[Switch 2 Pro] <-->|BLE| Bridge[NS2 Pro Bridge]
    Bridge <-->|Virtual Xbox HID| Games[macOS / games]
    Client[Local application] -->|Dual-band JSON socket| Bridge
    Bridge -->|DSU motion / UDP| MotionClient[DSU-compatible application]
```

- **Input**: CoreBluetooth reads buttons and calibrated sticks; CoreHID publishes an `Xbox Wireless Controller` device. Face buttons map by physical position. ZL/ZR become fully pressed Xbox triggers.
- **Controller window**: overlays live input on a controller photograph and displays connection state, device name and identifier, discovery-time RSSI and battery voltage from report05. Firmware battery level (0–9), charging and external-power flags appear only after a valid report09 arrives; the app does not infer a precise percentage. The native Settings window (`⌘,`) contains rumble strength, the dual-band and motion interfaces, and a 0.3-second vibration test.
- **Connection feedback**: plays the controller's built-in connection vibration, `0A/02` sample 3, after initialization.
- **Ordinary rumble**: Xbox output reports retain left/right intensity, timing and repeats. Left output uses 160 Hz and right output 320 Hz; trigger amplitudes merge into the corresponding main motor. This path cannot reconstruct the original HD vibration waveform.
- **Dual-band haptics**: applications can supply independent amplitude and frequency for the low/high bands on each side through a local JSON socket. Applications must explicitly integrate this interface.
- **Experimental motion**: an opt-in loopback DSU/Cemuhook server exposes report05 accelerometer and gyro data to compatible applications on `127.0.0.1:26760`, slot 0. Enable it in Settings before connecting. It uses default sensor ranges and monotonic receive timestamps. It does not add motion to Xbox HID.
- **Accessories**: report05 provides headphone insertion detection; with motion disabled, report09 also provides headphone/headset classification and the NFC processor's raw state. Detection does not enable NFC tag reading or audio streaming.
- **Lifecycle**: disconnect, sleep and exit clear vibration. A physical link loss retains the virtual device with neutral input until explicit disconnect or exit. Dual-band commands expire within one second and discard superseded ordinary effects; ordinary indefinite effects have a renewable five-second limit.

### HD vibration: frequency encoding

Each actuator receives two independent amplitude/frequency pairs, conventionally named LF and HF. Both frequency fields use the same logarithmic conversion in [NS2Rumble.c](Sources/NS2Transport/NS2Rumble.c):

$$
f_c=\mathrm{clamp}(f,40,1252),\qquad
q=\mathrm{round}\left(1+96\log_2\frac{f_c}{10}\right),\qquad
\hat f(q)=10\cdot2^{(q-1)/96}\ \mathrm{Hz}.
$$

There are 96 codes per octave: 80, 160, 320 and 640 Hz map to 289, 385, 481 and 577. Rounding contributes at most 6.25 cents, or approximately 0.362% relative frequency error, against the clamped target; this is a quantization bound, not a hardware accuracy claim. The 40–1252 Hz input range maps to codes 193–670. Its upper endpoint decodes to approximately 1252.57 Hz.

![Frequency encoding and acoustic residuals](docs/figures/rumble-frequency.png)

*Left: implemented conversion and acoustic peaks. Right: measured peak deviations from that conversion. The 16 carrier estimates come from two recordings of one controller at seven distinct codes, covering approximately 50–640 Hz; the observed deviations range from −0.103% to +0.114%. Peak estimation searches near the candidate frequency. These measurements support the conversion at the sampled frequencies, rather than establishing full-range accuracy or a confidence interval.*

The frequency code occupies all ten bits. In particular, HF code 577 (`0x241`) produced a peak near 640.49 Hz: bit 9 belongs to the frequency value, rather than being stripped as an enable flag. The two pairs are packed into one 40-bit little-endian word per actuator:

| Bits | 0–9 | 10–19 | 20–29 | 30–39 |
| --- | --- | --- | --- | --- |
| Field | LF frequency | LF amplitude | HF frequency | HF amplitude |

The five-byte words occupy offsets 2–6 and 18–22 of the 42-byte BLE payload. Each side has a preceding command byte: `0x50 | (sequence & 15)` for active output, or `0x10 | (sequence & 15)` to stop. A zero-amplitude band also receives frequency code zero; that zero is inactive, not a carrier to decode with the formula.

Amplitude is handled separately: `round(192 × gain × clamp(amplitude, 0, 1))`. At the default gain of 2, amplitude 0.5 becomes code 192. This scales amplitude codes while preserving both carriers; it does not calibrate actuator force or perceived intensity against a console. Ordinary Xbox rumble supplies intensity only, so its 160/320 Hz carriers are chosen by the adapter; the dual-band interface preserves application-supplied frequencies.

[Measurement data and method](docs/data/README.md) · [Vector SVG](docs/figures/rumble-frequency.svg) · [PDF](docs/figures/rumble-frequency.pdf). Regenerate all three figure formats with Python:

```sh
python3 -m pip install -r tools/requirements-figures.txt
python3 tools/plot_rumble_frequency.py
```

## Usage

Requires macOS 26+, a Switch 2 Pro controller and Bluetooth.

### Connect

1. Release the controller from any other application currently using it.
2. Open the app and use its window or menu-bar controls. It does not connect automatically.
3. Open **Settings** (`⌘,`) to select **Rumble Strength** (default 2×) and configure the local interfaces. The dual-frequency interface is enabled by default; **Share motion with local apps (DSU)** is off by default. Change these settings while disconnected.
4. Choose **Connect Controller** from the menu bar, or click the link icon in the controller window. Allow Bluetooth access if macOS requests it. Hold the controller's top SYNC button until the player lights flash. Wait for **Controller connected** and check the player light, then start the game.

Choose **Disconnect Controller** from the menu bar, click the disconnect icon in the controller window, or quit the app to release the controller. Closing the last app window hides the Dock icon and keeps the bridge running in the menu bar. Sleep disconnects it; reconnect manually after waking. The default gain comes from earlier user testing, rather than console calibration.

### Controls

| Switch 2 Pro | Xbox output |
| --- | --- |
| A / B / X / Y | B / A / Y / X |
| L / R | LB / RB |
| ZL / ZR | LT / RT, fully pressed |
| + / − | Start / Back |
| Stick clicks / D-pad | Stick clicks / D-pad |
| Home / Capture | Guide / Share |

Games may handle Guide and Share differently. Controller recognition and ordinary rumble depend on the target game's controller support.

## Local dual-band interface

When connected with **Allow local apps to send dual-frequency rumble** enabled in Settings, the app binds `~/.ns2pro-bridge/haptics.sock`, a Unix datagram socket accessible only to the current user. Each UTF-8 JSON datagram supplies a complete frame for both sides. A standard-library Python client is included:

```sh
python3 tools/haptics.py \
  --left  0.15 160 0.1 320 \
  --right 0.15 160 0.1 320 \
  --seconds 1
```

Each side takes low amplitude, low frequency, high amplitude and high frequency. This command drives a connected controller. Amplitudes range from 0–1 and frequencies from 40–1252 Hz; the earlier acoustic measurements covered approximately 50–640 Hz. Sustained effects should renew a 200 ms lease about every 50 ms. A successful send confirms datagram delivery to the kernel, not motor execution.

See the [v1 protocol](docs/native-haptics.md) for the JSON schema, lease and stop behavior, arbitration and errors.

## Local motion interface (experimental)

Enable **Share motion with local apps (DSU)** in Settings before connecting the controller. In a DSU/Cemuhook-compatible application, set the server to `127.0.0.1:26760` and select slot 0. Buttons and sticks continue through Xbox HID; DSU supplies accelerometer and gyro data only.

The included standard-library client can inspect received motion packets:

```sh
python3 tools/dsu-monitor.py --seconds 10
```

Motion mode does not subscribe to report09, so firmware battery level, charging, external-power and NFC state are unavailable while it is enabled. Battery voltage and headphone insertion detection remain available. Disconnect before changing the motion setting.

## Known limitations

- One controller over Bluetooth; no USB, iOS or iPadOS support.
- Motion uses default sensor ranges without factory or user calibration. Real BLE-to-DSU streaming and disconnect cleanup have been tested on one controller; axis directions in target emulators and sensor accuracy remain unverified.
- C, GL and GR are detected and displayed in the controller window but are not forwarded to Xbox HID. No button remapping or per-game profiles.
- NFC and headphone support is limited to status detection. NFC tag reading/writing and Bluetooth headphone audio are not implemented; headphone insertion and headset classification still need physical verification. USB headset audio is a separate system-device path and is not implemented or verified by this Bluetooth adapter.
- No launch at login or automatic updates.

See [motion and accessory protocol notes](docs/motion-accessories.md) for the DSU interface, evidence and remaining protocol gaps.

## License

The project code uses the [MIT License](LICENSE) and retains upstream attribution. The controller photograph is copyrighted by Nintendo and is not covered by MIT; see its [source and rights notice](Resources/Controller/ATTRIBUTION.md). Other notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The repository contains no game resources, keys, saves or game runtime.
