# unproc

**a camera for real photos. zero processing.**

your phone's camera app doesn't take photos, it takes guesses. it stacks frames,
smooths skin, lifts shadows, sharpens edges that were never there and paints
the sky a colour the sky wasn't. unproc doesn't. one press, one exposure, read
straight off the sensor and developed like film: honest grain, real highlights,
shadows that stay dark.

iOS 26+. no accounts, no network, no dependencies.

## features

- **raw by default.** plain bayer RAW off a single physical lens. no deep
  fusion, no smart hdr, no night mode, no multi-frame anything. apple proRAW
  is there if you want it.
- **neutral development.** zero sharpening, zero local tone mapping, zero
  detail boost. a gentle film-like curve, a touch of noise reduction, lens
  distortion corrected. that's it.
- **looks.** a small set of subtle colour grades built as 3D LUTs. the exact
  same transform runs live in the viewfinder and on the full-res photo, so what
  you see is what you get. `ZERO` is no look at all.
- **jpeg or jpeg + raw.** the developed jpeg lands in photos with the original
  DNG attached to the same asset.
- **pro mode.** manual iso, shutter (long exposures simulated in the preview),
  white balance, focus. zebras and focus peaking.
- **tap to focus, hold to track.** long-press a subject and focus follows it.
- **double exposure.** two frames, one photo.
- **camera control.** on iPhone 16 and later, the camera control button shoots,
  and its slider does exposure and looks.
- **lock screen.** launch it from the lock screen, control centre or the action
  button without unlocking. shots taken while locked move into photos the next
  time you open the app.

## how the pipeline works

```
sensor ─▶ RAW (bayer / proRAW, one physical lens, quality = speed)
       ─▶ CIRAWFilter  sharpness 0 · local tone map 0 · detail 0 · boost ~0.5
                       modest luminance NR · lens correction · no EDR
       ─▶ orient + crop (2× modes are honest centre crops)
       ─▶ look (3D LUT)            ─▶ double exposure blend (optional)
       ─▶ display-P3 JPEG q0.93 + original EXIF  (+ untouched DNG)
       ─▶ Photos  /  lock-screen session folder
```

lenses that can't shoot RAW (the front camera) fall back to the least processed
image the system will hand over.

## building

you need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Unproc.xcodeproj
```

pick your team under *Signing & Capabilities* for all three targets
(`Unproc`, `UnprocCapture`, `UnprocWidgets`), change the `lol.peril.unproc`
bundle id prefix in `project.yml` if you need to, and run on a device. the
camera doesn't work in the simulator.

**no Mac?** every push to `master` builds an unsigned IPA on GitHub Actions.
grab `unproc-unsigned-ipa` from the latest run (or the IPA attached to a
release) and re-sign it with your own team using the sideloading tool of your
choice (AltStore, Sideloadly, `zsign`, …).

## project layout

```
project.yml                  XcodeGen spec (the .xcodeproj is generated, never committed)
Unproc/
  App/                       app entry point, lock-screen capture importer, Info.plist, assets
  CaptureExtension/          lock-screen camera (LockedCameraCapture, ExtensionKit)
  Widgets/                   control centre / lock screen / action button control
  Intents/                   UnprocCaptureIntent (CameraCaptureIntent) + settings sync
  Shared/
    Core/                    shared types: settings, lenses, looks, capture contracts
    Camera/                  AVFoundation capture, focus, exposure, tracking
    Pipeline/                RAW development, looks, double exposure, viewfinder effects
    UI/                      camera screen, viewfinder, controls
    Viewer/                  thumbnail + photo viewer
.github/workflows/build.yml  CI: build + unsigned IPA, attached to v* releases
```

see [ARCHITECTURE.md](ARCHITECTURE.md) for the module contracts.

## license

MIT. see [LICENSE](LICENSE).

## Credits

`Unproc/App/DemoScene.jpg` (used only by the simulator demo feed for CI screenshots) is a photo from [Unsplash](https://unsplash.com/photos/1500530855697-b586d89ba3ee), used under the Unsplash License.

## Dependencies

- [Glur](https://github.com/joogps/Glur) (`GlurBackdrop`) — the progressive blur on the top and bottom edges of the 16:9 viewfinder. Note: `GlurBackdrop` uses a private Core Animation API; fine for sideloading, review before an App Store submission.

## Camera Control (iPhone 16 and later)

- **Open unproc with the button:** Settings › Camera › Camera Control › Launch Camera › **unproc**. unproc is eligible because it ships a Lock Screen capture extension; it also works from the Lock Screen and Control Centre.
- **In the app:** press to take a photo. Light-press and slide to switch between **Zoom** (snaps to your lens stops), **Exposure**, **Look** and **Ratio**. They stay in sync with the on-screen controls.
