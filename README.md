# NetStatusBar

Small macOS menu bar app that pings a target host and shows internet status:

- green indicator: ping succeeds
- red indicator: ping fails
- notification when connection status changes
- `Sosumi` system sound when the internet is marked offline
- `Funk` system sound when the internet is restored
- menu actions to enable notifications and send a test notification
- debounce against flaky ping results: 3 missed checks to go offline, 2 successful checks to recover
- default target: `1.1.1.1`

## Build

```bash
./build_app.sh
```

The app bundle is created at:

```text
outputs/NetStatusBar.app
```

## Run

```bash
open outputs/NetStatusBar.app
```

Click the menu bar indicator to check now, change the target IP/host, or quit.
