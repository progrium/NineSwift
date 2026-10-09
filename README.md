# NineSwift

A [9P](https://en.wikipedia.org/wiki/9P_(protocol)) client library for Swift, with a command-line client and a file explorer app for macOS, iOS, watchOS and tvOS.

* High quality protocol implementation via interactive "curriculum" tool [Virgil](https://joel.franusic.com/virgil/)
* Keep code radically simple, near single file sources
* No Xcode files or cruft, just Swift files and a Makefile
* Simple, consistent UI across Apple devices 

## What's here

| Path | Contents |
|---|---|
| [NineP/](NineP/) | `NineP.swift`, the 9P2000 / 9P2000.L client library (single file) |
| [NineClient/](NineClient/) | `NineClient`, a CLI for talking to 9P servers |
| [NineExplorer/](NineExplorer/) | NineExplorer, a file explorer app: shared core plus one file per platform |

## Building

You need macOS with Xcode installed (for the platform SDKs). There's no Xcode project; everything builds with `make`.

```sh
git clone https://github.com/progrium/NineSwift.git
cd NineSwift
make                 # CLI, plus the macOS, iOS and tvOS apps
```

Outputs go to `build/`. Individual targets:

| Target | Builds / runs |
|---|---|
| `make build/NineClient` | the CLI |
| `make mac-app` | `build/macOS/NineExplorer.app` |
| `make ios-app`, `tv-app`, `watch-app` | simulator builds of the other apps |
| `make iphone-sim`, `tv-sim`, `watch-sim` | build, install and launch in a simulator |
| `make tv-device` | build, install and launch on an Apple TV (see below) |
| `make clean` | remove `build/` |

## Usage

```sh
build/NineClient host:564 ls -l /
build/NineClient --proto 9P2000.L host:564 cat /etc/motd
build/NineClient --help              # all flags and commands
```

The macOS app takes the same connection flags. Without a server address it opens a connect screen:

```sh
build/macOS/NineExplorer.app/Contents/MacOS/NineExplorer host:564
```

## Running on an Apple TV

You need Xcode, a paid Apple Developer account, and the Apple TV on the same network as your Mac.

1. **Pair the Apple TV.** On the Apple TV, open Settings → Remotes and Devices → Remote App and Devices. On the Mac, open Xcode → Window → Devices and Simulators and pair it. Check that it appears with `xcrun devicectl list devices`.
2. **Get a signing certificate.** In Xcode → Settings → Accounts, add your Apple ID and click Manage Certificates → + → Apple Development.
3. **Create a provisioning profile** at [developer.apple.com](https://developer.apple.com/account/resources):
   - Register an App ID (e.g. `com.yourname.NineExplorer`).
   - Register the Apple TV under Devices. Its identifier is shown in Xcode's Devices window.
   - Create a tvOS App Development profile for that App ID and device, then download it.
4. **Build, install, and launch:**

   ```sh
   make tv-device TV_PROFILE=path/to/NineExplorer_tvOS.mobileprovision
   ```

   The bundle ID and entitlements are read from the profile. The Apple TV and signing identity are picked automatically. To choose them yourself, set `TV_DEVICE=<name or id>` and `IOS_SIGN_ID="Apple Development: ..."`.


## Dev VM

`.dev/vm` runs a macOS VM with Xcode, using [Lima](https://lima-vm.io). Builds run in the VM and don't touch your host. You need an Apple Silicon Mac and Lima (`brew install lima`).

```sh
.dev/vm base-init     # one-time: create the xcode-base VM and install Xcode + iOS/watchOS/tvOS SDKs
.dev/vm up            # clone xcode-base into nineswift-dev (first time only) and start it
.dev/vm shell make    # run a command in the VM against this repo (synced with --sync)
.dev/vm shell         # or open an interactive shell
.dev/vm stop          # stop the VM
.dev/vm reset         # delete nineswift-dev; the next `up` starts again from xcode-base
```

`base-init` asks you to set a password for the VM user, because the Xcode install needs `sudo`. It then runs [.dev/base-provision](.dev/base-provision). It takes a while, but you only run it once. Settings are at the top of `.dev/vm`: `BASE_TEMPLATE` (Lima macOS template), `XCODE_VERSION`, and `CPUS`/`MEMORY` for `nineswift-dev`. Change the first two before running `base-init`.

## License

MIT
