<h1 align="center">Gridura</h1>

<p align="center">
  A full-screen app launcher for macOS 26 and later: your apps in a paged or scrolling grid, with folders,
  drag-and-drop ordering, search and Liquid Glass.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-111?logo=apple&logoColor=white" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-AppKit%20%2B%20SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/status-early%20preview-orange" alt="Early preview">
  <img src="https://img.shields.io/badge/language-English%20%7C%20T%C3%BCrk%C3%A7e-4ade80" alt="English | Türkçe">
</p>

<p align="center">
  <b>English</b> · <a href="README.tr.md">Türkçe</a>
</p>

---

macOS 26 (Tahoe) removed Launchpad. Gridura brings back a grid of your apps that you can arrange the way you like:
open it with a hotkey, a pinch, a hot corner or the menu bar, find an app, launch it, and get out of the way.

> **Status: early preview (0.0.1).** The core is working and covered by automated UI tests, but it has had little
> real-world use yet. Expect rough edges and please report them as [issues](https://github.com/Gorke07/Gridura/issues).

## Features

### The grid
- **Paged or scrolling**, full screen or in a window. Choose the number of columns and rows.
- **Folders:** drop one app on another to make a folder; reorder inside it, drag an app out to detach it, rename with a click.
- **Drag and drop:** reorder icons, move them across pages (hold at the screen edge to flip the page), drag several at once.
- **Multi-select:** ⌘-click or ⌘-drag a rubber band, then use the menu to move, group into a folder or hide the selection.
- **Sorting:** custom order, by name, by date added or by date last opened. **Reorganize** fills gaps and can sort by name,
  date, last use or icon color, keep or flatten folders, and place Apple apps first or last.
- **Backgrounds:** your blurred wallpaper (needs Screen Recording permission) or a Liquid Glass material of five strengths.

### Search
- Type anywhere to search; no need to click the field first. Matching ignores case and diacritics (`masaustu` finds *Masaüstü*).
- ↩ opens the top result. Arrow keys move the selection. Esc clears the search, then closes the launcher.

### Opening it
- **Global hotkey** (⌥Space by default, configurable), the **F4 key**, a **trackpad pinch** (3, 4 or 5 fingers),
  **hot corners**, or the **menu-bar icon**.
- Click on empty space or press Esc to close; swipe on empty space to change pages.

### Managing apps
- **Hide** apps you never launch, **rename** them, **show in Finder** or **get info** from the context menu.
- **Uninstall** an app together with its leftovers (caches, preferences, containers…) — a scan lists everything before
  anything is moved to the Trash. Optionally hold ⌥ to enter uninstall mode.
- **Backup and restore** your layout, or **import** the old system Launchpad layout.

### Details
- English and Turkish interface; optional start at login and menu-bar icon.
- Five app icons to choose from, all drawn for this project.
- Updates through [Sparkle](https://sparkle-project.org) with signed releases.

## Requirements

- macOS 26.0 or later (Apple silicon or Intel).
- Optional permissions: **Accessibility** (F4 key and trackpad pinch), **Screen Recording** (wallpaper background),
  **Full Disk Access** (finding all leftovers when uninstalling). Gridura asks only when you turn a feature on.

## Building from source

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/Gorke07/Gridura.git
cd Gridura
xcodegen generate          # creates Gridura.xcodeproj from project.yml
open Gridura.xcodeproj     # run the "Gridura" scheme
```

`Gridura.xcodeproj` is generated; change `project.yml` rather than the project file.

### Tests

Debug builds contain a UI self-test harness that drives the real launcher with genuine mouse and keyboard events.
It refuses to run without a scratch store, so your own library is never touched:

```bash
mkdir /tmp/gridura-test
GRIDURA_SELFTEST=realdrag-app GRIDURA_STORE_DIR=/tmp/gridura-test \
  "$(find ~/Library/Developer/Xcode/DerivedData -path '*Debug/Gridura.app/Contents/MacOS/Gridura' | head -1)"
cat /tmp/gridura_selftest.log
```

Modes include `drag`, `merge`, `multi`, `folder`, `hide`, `realdrag-app`, `realclick`, `realsearch`, `realrename`,
`tour` and the `shot-*` screenshot modes (see `Gridura/App/SelfTest.swift`). Real-event modes need Accessibility
permission for the terminal or Xcode that launches them.

## Project layout

| Path | Contents |
|---|---|
| `Gridura/App` | app lifecycle, menu bar, update manager, self-tests |
| `Gridura/Presentation` | window, grid, folders, drag and drop, search view |
| `Gridura/Model` | Core Data store, layout normalisation, search, app scanning |
| `Gridura/Input` | hotkey, F4, trackpad pinch, hot corners |
| `Gridura/Settings` | the settings window and onboarding |
| `Gridura/Uninstall` | the uninstall window and leftover scan |
| `Scripts` | icon generator and the release script |
| `docs` | implementation status and the release guide |

## Releasing

See [`docs/release.md`](docs/release.md). In short: bump the version in `project.yml`, update both changelogs, run
`Scripts/build-release.sh`, publish the GitHub release, then push `appcast.xml`.

## Contributing

Issues and pull requests are welcome. Describe what you expected and what happened, and include your macOS version.
Before opening a pull request, run the self-tests that cover the area you changed.

## License

Gridura is released under the [MIT License](LICENSE). Third-party components are listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Acknowledgements

Built with [Sparkle](https://sparkle-project.org) for updates. Gridura is an independent project and is not affiliated
with Apple.
