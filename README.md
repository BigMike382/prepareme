# PrepareMe 4.0: source

PrepareMe is an offline preparedness reference library for iPhone and iPad, built on the open-source
[Kiwix](https://github.com/kiwix/kiwix-apple) reader. This repository holds the source of each build of PrepareMe sent
to the App Store, one commit and tag per build (this one: `v4.0-2026.1123.2333`); the main branch holds the newest. It is released
under the GNU General Public License, version 3: see `LICENSE`, and `NOTICE.md` for what was changed from Kiwix and
when.

The app's support page and privacy page are in `docs/` and are served at <https://bigmike382.github.io/prepareme/>.

## What is here

- `app/Kiwix`: Kiwix for Apple 3.17.1 with PrepareMe's changes (`NOTICE.md` lists every file added or changed).
- `app/Service`: PrepareMe's shared code (the phone app's library, inventory, maps, documents and conditions code),
  and the service the companion Mac app runs for paired phones.
- `app/StreetMapAssets`: the offline street map's page, styles, fonts and icons, with each part's license beside it,
  and `make_web.sh`, which fetches and checks the map engine's files.
- `app/Meaning`: meaning search, and `make_model.sh`, which downloads and converts its model (bge-small-en-v1.5, MIT).
- `app/AppIcon`: the script that draws the app's icon.
- `kiwix-mac/build.sh`: the script that builds the app, with the files it calls; `guard/` holds the checks its upload
  step runs.

Not here: the library content (guides, maps and the sample library are data, made and delivered separately), and the
Mac jobs that make a household's library.

## Building the phone app

On a Mac with Xcode in `/Applications`:

1. A Python 3.10 or newer at `~/.venvs/prepareme-app/bin/python` (`build.sh` runs Kiwix's `localizations.py` with it).
2. Two downloads, put in `~/Library/Application Support/PrepareMe/tools/kiwix-build/`; `build.sh` checks each against
   its pinned checksum before using it:
   - Kiwix's binary library, libkiwix 14.2.1:
     <https://download.kiwix.org/release/libkiwix/libkiwix_xcframework-14.2.1-2.tar.gz> (MD5
     `78c0398d14228d11d2caf2c888314d04`)
   - XcodeGen 2.46.0: <https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip> (SHA-256
     `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`)
3. Optional: meaning search's model, made by `app/Meaning/make_model.sh`. Without it the app searches by words alone.
4. Then, from this folder: `kiwix-mac/build.sh --app-sim` builds the app for the iPhone simulator. The Swift packages
   are pinned by `app/Kiwix/Package.resolved`.

A build from this repository offers no Try the Sample: the sample library is not part of the source. For the same
reason `--app-store-check` and `--app-store`, which build the App Store version with its sample, refuse to run here.
`--test` and `--tsan` aren't supported from this repository either: the program that makes their test libraries reads
a file that isn't part of it.

## Kiwix's binary library and its sources

The library above is Kiwix's own build. It contains, at these versions:
[libkiwix](https://github.com/kiwix/libkiwix) 14.2.1 (GPL 3),
[libzim](https://github.com/openzim/libzim) 9.7.0 (GPL 2 or later),
[Xapian](https://xapian.org) 1.4.23 (GPL 2 or later),
[ICU](https://icu.unicode.org) 73.2 (Unicode License),
[curl](https://curl.se) 8.4.0 (curl license),
[libmicrohttpd](https://www.gnu.org/software/libmicrohttpd/) 0.9.76 (LGPL 2.1 or later),
[XZ Utils' liblzma](https://tukaani.org/xz/) 5.2.6 (public domain),
[Zstandard](https://github.com/facebook/zstd) 1.5.7 (BSD),
[zlib](https://zlib.net) 1.3.1 (zlib license),
[pugixml](https://pugixml.org) 1.15 (MIT) and
[Mustache](https://github.com/kainjow/Mustache) (Boost Software License).
Kiwix's build recipe for it is [kiwix-build](https://github.com/kiwix/kiwix-build).
