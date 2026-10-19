# MotionSource NX

Install the unsigned `MotionSourceNX.ipa` using your usual sideloading method.
Close the original MotionSource before opening this build. Allow Local Network
and Motion access when requested, select Portrait, leave the accelerometer on,
and tap **Start Server**. Enter the displayed IP and port in the Mac game's
**Motion → Connect Phone…** menu. The default port is `26760`.

The server keeps the screen awake while running. Manually locking the phone or
leaving the app releases the UDP port; returning resumes on the same port.
A lost client leaves the server listening. Socket failures display their cause
and retry on the same port every two seconds. **Stop Server** cancels recovery.
The last socket error remains visible after a retry, including the Mac address,
error domain/code and the failed socket operation. It clears after a successful
reply or when the server is stopped.

If the phone reports **No route to host** when the Mac connects, check the
phone's Local Network permission and VPN routing. On devices with per-app
Wireless Data settings, also allow this app to use Wi-Fi; that setting is
independent of Local Network permission. Keep the port unchanged while checking
these settings.

On a send failure with error 65, the app also uses Apple's Network framework to
check the path to the requesting Mac. This may request the system network
authorization that a listening UDP socket has not requested yet. The check sends
no application data. It reports iOS's specific Local Network, Wi-Fi or VPN
restriction when available and offers **Open App Settings** for denied access.
An allowed path is reported separately from a successful motion send.

This is a patched build of [MotionSourceiOS](https://github.com/shiftinv/MotionSourceiOS),
not an upstream release. The patch adds lifecycle/port recovery, a visible status,
explicit main-queue sensor callbacks, stale-callback isolation, request length/CRC
validation and accurate button state. The build declares sensor permissions and
uses the original motion axes and DSU protocol. It does not run while locked or
in the background.

Build from a terminal or Spyder F5:

```
python3 scripts/build_motion_source.py /Volumes/Games/MotionSourceNX
```

Requires Xcode and XcodeGen. The script fetches these pinned public sources into
the specified output directory, applies `motionsource.patch`, and builds without
CocoaPods or signing. It also creates `MotionSourceNX-source.zip`, containing the
modified sources, dependency, licenses, project and build script.

- MotionSourceiOS: `65d402873906bc44fe2e627089a6a0fe4c4ef077`, LGPL-2.1.
- CocoaAsyncSocket: `4b88ce116b0ecbf974776c6a5f027c1bb90e0fd4` (7.6.3), public domain.

The MotionSource patch follows its upstream LGPL-2.1 license; the complete
upstream license is included in the source archive. See the upstream About page
for its icon attribution. This helper is separate from the game IPA.

The source archive is also directly buildable: extract it, run `xcodegen generate`,
then build the `MotionSourceNX` scheme with signing disabled. Its root `Info.plist`
contains the permission descriptions used by the packaged app.

For local lifecycle QA without an iPhone or a simulator runtime:

```
xcodebuild -project MotionSourceNX.xcodeproj -scheme MotionSourceNX \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  CODE_SIGNING_ALLOWED=NO test
```

The hosted tests use the real UIKit controller and actual loopback UDP sockets.
They cover repeated start/stop on one port, DSU replies, suspension/resumption,
stale close callbacks and automatic recovery after socket closure. Hardware
sensor data and real lock/unlock behavior still require the iPhone test.
