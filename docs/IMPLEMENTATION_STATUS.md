# Gridura — implementation status

Working list derived from the behaviour audits of each subsystem. `[x]` done, `[ ]` open, `[-]` deliberately out of scope.
Update this file as items land.

## folders, drag & drop, multi-select, hide animation
- [x] Single-item drag (grid, paged + scroll), hover delay, reorder, merge, edge page flip, drop animation, persistence
- [x] In-folder reorder and detach (drag out closes the folder)
- [x] Multi-select (⌘-click, ⌘-drag marquee), multi-selection menu + batch actions, layout-change animation
- [x] Multi-drag stack (cards, badge, gather, paging, merge) — Pro-gated drop
- [x] Hide animation
- [x] Dock hand-off + overlay window (§5.7)
- [x] Folder context menu (Open / Rename / Move to / Ungroup), ungroup placement, folder merge scale + highlight
- [x] Real-pointer drag: reproduced with genuine HID mouse events in the genuine launcher window (`realdrag`, `realdrag-app`) — reorder works and persists; the user-reported revert did not reproduce

## grid, search, icons
- [x] Empty-area right-click / ⌃-click opens the background menu
- [x] "Move to" submenu (Page N, folders with ✓)
- [x] "Add App to Dock" disabled when already in Dock; Uninstall needs Pro + removable app
- [x] Pro gating for Hide / Rename / Uninstall / Window + Scroll items
- [x] Background menu: sort-order submenus, Get Pro / Activate, update items, Restart
- [x] Display-mode switch from menu re-frames the window (applyDisplayMode / relayoutWindowFrame)
- [x] Click on the title text starts rename; rename editor visuals + commit-on-blur
- [x] Mouse-drag paging in window mode, precise-scroll without phase
- [x] Esc / Return / type-to-search / Option-hold guards (§6.4)
- [x] Search return position (scroll mode)
- [x] Open / Show in Finder / Get Info dismiss the launcher first (presentationRequestID)
- [x] Uninstall button cleanup (hideUninstallButton removeFromSuperview)
- [x] Icon cache hit applies without fade
- [x] ToastManager host leak, bottom inset, tint
- [-] Hidden-app badge in search results — placement could not be determined
- [x] Scroll mode: scroller in window mode, no per-layout cell rebuild

## presentation / window
- [x] Wallpaper crossfade (0.36 s) + CPU blur fallback
- [x] dockScreen orientation clamp
- [-] Dock-tile plug-in (separate bundle target)

## data
- [x] Reorganize: per-page scope, folder/Apple placement, icon-colour sort, per-direction options, sortBy=.custom + refresh
- [x] ceil() page count, compactPages-only normalizer
- [x] Backup import: post `.systemData`, update IconGrid, UTType declaration
- [x] Native Launchpad import via sqlite C API

## input
- [x] User-recordable hotkey (Carbon registration), stored as `KeyboardShortcuts_launchApp`
- [x] F4/Launchpad key via CGEventTap (swallow), accessibility gating
- [x] Pinch gesture state machine (finger counts, thresholds, TrackpadGesture setting)
- [x] Sleep / wake / lock handling (rebuild monitors)
- [x] Hot corners: all screens, debounce, exact corner; system hot-corner conflict (`-modifier`)

## settings, onboarding, uninstall, Pro
- [x] Uninstall window (560×400, grouped scan list) + full leftover scan + robust removal + Force Quit
- [x] Full Disk Access gate / permissions window
- [x] General trial bar logic, shortcut recorder row, Multi-Select button, guide page 1 rows
- [-] Manage Devices sheet — needs the vendor licence server
- [-] What's New card — vendor release content (CDN image, release notes URL)
- [x] Localisation (tr/en `.strings`)
- [x] Updates through the Sparkle framework (SPM, EdDSA-signed archives, `SUFeedURL` + `SUPublicEDKey` in `project.yml`): gentle scheduled reminders drive the badge, menu items and General-tab bar; the Update buttons open Sparkle's window; `update` self-test serves a local appcast and checks the newest version is reported; release pipeline in `Scripts/build-release.sh`, documented in `docs/release.md` (verified: ad-hoc DMG builds, `generate_appcast` signs with the `gridura` key, bilingual notes are embedded). Not yet exercised: Developer ID signing, notarization and a real install from a published release
- [x] Licensing removed entirely (no Pro/trial/activation/paywall); every feature is always available

## Settings review (rendered with `shot-*` hooks)
- [x] General, Interface, Apps, Advanced, About tabs reviewed and fixed (recorder width, row heights, Cryptex name, backup Replace sheet, own display-mode previews, preset reset removed)
- [x] Own icon set (app, five Settings choices, Logo, menu bar) + display-mode previews: `Scripts/generate_icons.swift`
- [x] Vendor links (About) and the feedback form removed (feedback goes through GitHub issues); version is Gridura 0.0.1
- [x] All artwork is now own work (`Scripts/generate_icons.swift`): app icons, Logo, display-mode previews, toolbar/search/status glyphs (SF Symbols), ✕ button, guide background + confetti; unused original assets deleted
- [x] Dark appearance checked with real window captures (`shot-prefs` with `GRIDURA_SHOT_DARK=1`, `shot-guide`)
- [x] Verified with real events: global hotkey (Carbon, press/release), F4 CGEventTap (keyCode 131 + fn), uninstall + Full Disk Access panels rendered (`hotkey`, `f4`, `shot-uninstall`)
- [x] Pinch state machine (`pinch`: began → rate-limited progress → completed, hidden-launcher spread ignored) and the real removal path (`trash`: probe app + leftovers scanned and moved to the Trash) verified
- [x] Found and fixed with a screenshot of the real launcher after a real drag (user report "all icons vanish after moving"): `LaunchpadAppIconView.apply(fade:false)` left the icon layer at opacity 0 on cache hits; the test now asserts every icon is drawn
- [x] Folder open/close animation checked frame by frame in the real launcher window (`folder-anim`): grows from the folder icon, shrinks back onto it
- [x] Visual tour of the real launcher (`tour`: grid, search, uninstall mode, scroll mode, window mode) found and fixed: long app names vanished entirely in window mode (CATextLayer drew nothing when the name was wider than the cell) — titles are now truncated with "…" in code
- [x] Every interaction test now asserts that all app icons are drawn (drag, merge, multi, hide, folder open/reorder/detach)
- [x] `realdrag-app` passed 9 of 10 runs (the one miss came right after another test process exited; not reproduced in 9 repeats)
- [x] Dock hand-off (`dockdrag`): with real mouse events a drag over the Dock strip starts the genuine AppKit drag session; releasing elsewhere ends it cleanly (nothing was ever dropped on the user's Dock)
- [x] Smoothness: a pure reorder drop now publishes content-only (cells are kept) and defers the Core Data save 0.15 s (flushed on quit); a main-thread stall probe (`FrameProbe`, 240 Hz timer) measures ≤17 ms stalls during real drag+drop and folder open/close (set `GRIDURA_SHOTS=1` / `GRIDURA_SHOT_MID=1` (+ `GRIDURA_BACKDROP=1` for a colourful stand-in wallpaper) for screenshots, which themselves stall the loop)
- [x] A dragged app icon rides on a Liquid Glass tile with a soft shadow (like the folder preview)
- [x] Layout passes during a drag no longer snap cells back to the stored order (user report: icon returns to the old place, then jumps to the new one): paged single/multi drags reconcile to the in-flight order, folder drags use the in-flight folder order, scroll mode is not rebuilt mid-drag; every drag test also passes with `GRIDURA_STRESS_LAYOUT=1` (a relayout every 30 ms)
- [x] Drop: during the 0.36 s fly-back the grid used to snap to the stored order (traced with `GRIDURA_TRACE_DROP=1`: source cell x 964 → 461 → 964); reconcile now also runs after release, until the commit
- [x] Folder-creation hover: the merge glass was a hard square (NSGlassEffectView ignores the layer's cornerRadius); it now uses `cornerRadius`
- [x] Empty space: a cell only owns its icon and title text (`hitTest`), so a click in the padding of a slot hides the launcher and a horizontal drag there swipes pages (`realclick`, real HID events: padding click hides, empty-space drag pages, margin click hides)
- [x] Page transition: the strip's layer position was set to `W*page + W/2` (wrong for a layer whose position is its origin) so the animation ended off-grid; now animates to the true rest position with an under-damped spring that carries the swipe's release velocity
- [x] Search typing (`realsearch`, real key events): every letter used to replace the previous one (the key monitor re-focused the field, which selects all) and Delete inserted a control character; the focused field now handles its own keys. Verified: "c","h","r","o" → "chro", Delete shrinks, emptying restores the full grid, Esc clears then hides
- [x] Search semantics (`realsearch2`, real key events): "masaustu" matches "Masaüstü" (diacritic-insensitive), "calculator" ranks Calculator first, Return with nothing selected opens the top result and hides the launcher (it used to do nothing)
- [x] Page scrolling continuity: the rubber band applied everywhere (a swipe was squashed after ~60 pt); it now resists only past the first/last page, and the live offset eases toward the pointer through a display link (`updatePagedDragFrame` factors 0.21 / 0.42); verified `mid-swipe: pointer dx=-324 → strip x=-295`
- [x] Scroll mode: the document height counted only full rows (an open question in the behaviour notes), so the last partial row was unreachable; fixed with ceil, checked in `tour`
- [x] Folder renaming (`realrename`, real mouse + key events, Turkish letters): Return in the title editor was swallowed by the grid's key monitor (never committed) → editor now gets Return and the arrows; the grid cell kept the old title after a rename (title refit skipped for an unchanged width, and reused cells were not re-synced) → `syncIfNeeded` + forced refit. Verified: click title → type → Return commits and persists; Esc cancels; click-away commits; grid-cell rename shows the new name
- [x] Add to Dock (Settings, guide, app menu): the old AppleScript (`add theApp to the dock`) is not a System Events command and silently failed; now the tile is written to the Dock's `persistent-apps` preferences and the Dock restarted. `dock` self-test runs against a scratch preferences domain (tile shape matches the Dock's own entries, no duplicates, the real Dock untouched). Gridura only adds itself from an Applications folder
- [-] Left to a person: the physical trackpad gesture (the state machine itself is verified) and the Dock actually adding a dropped app (that is the Dock's behaviour and would modify the user's Dock)

## Test hooks (DEBUG builds only)
`GRIDURA_SELFTEST=<tour|folder-anim|dockdrag|pinch|trash|realdrag|realdrag-app|hotkey|f4|shot-uninstall|shot-guide|drag|merge|multi|hide|folder|reorg|scan|update|shot-general|shot-interface|shot-apps|shot-advanced|shot-about|shot-prefs>` with `GRIDURA_STORE_DIR=<scratch dir>`
runs a headless UI check and writes `/tmp/gridura_selftest.log` (see `Gridura/App/SelfTest.swift`).
It refuses to run without a scratch store, so the real library is never touched.
