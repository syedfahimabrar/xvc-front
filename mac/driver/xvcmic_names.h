// Rebrand constants for the "XVC Mic" virtual device.
//
// Injected ahead of BlackHole.c with clang's `-include`, not with `-D`. Every constant
// below is `#ifndef`-guarded in BlackHole.c, so defining it first wins.
//
// Why not GCC_PREPROCESSOR_DEFINITIONS, as BlackHole's README suggests? Because the device
// name contains a space, and `-DkDevice_Name="XVC Mic"` is split on that space before clang
// sees it (`error: expected ')'`). Escaping doesn't help: xcodebuild strips the backslash,
// so `"XVC\40Mic"` reaches the compiler as the literal `XVC40Mic` — it builds fine and
// silently produces a device named "XVC40Mic". A header sidesteps the shell entirely.
//
// BlackHole is MIT licensed (github.com/ExistentialAudio/BlackHole). We do not modify or
// redistribute its sources; the build script clones them at a pinned tag. Ship its LICENSE
// with any binary we distribute.

#pragma once

#define kDriver_Name        "XVCMic"                  // derives the device UID: XVCMic2ch_UID
#define kPlugIn_BundleID    "se.kth.xvclivemic.driver"
#define kPlugIn_Icon        "BlackHole.icns"          // the icns that ships in the bundle

// What Zoom, Meet and Teams show in the microphone picker.
#define kDevice_Name        "XVC Mic"
#define kDevice2_Name       "XVC Mic Mirror"          // hidden mirror device, BlackHole's design

// 2 channels at 44.1/48 kHz: meeting apps expect a normal-looking device. The Mac app
// resamples the server's 16 kHz output up to the device rate before rendering into it.
#define kNumber_Of_Channels 2
