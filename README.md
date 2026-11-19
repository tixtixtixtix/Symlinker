# Symlinker

A native SwiftUI droplet for Droppy. The idle view contains two file tiles and a detached rounded progress track, inside the host's standard notch width. No title or instructional footer is shown.

Click or drop one source file/folder and one destination folder. **Create Symlink** appears when both are selected. Existing files and links, including broken links, are never overwritten.

The creation animation dissolves the destination, overlaps the original and duplicate, stretches across both tiles, and splits into two rounded rectangles. An elapsed-time clock, independent of button transitions, drives staggered spring recoil, tall and skinny rebound, restrained motion trails, and blur that resolves to sharp resting tiles. The badge and track appear during the settle; the action label blurs and slides through confirmation into Show in Finder. With Reduce Motion, the tiles remain still and the center track fills instead.

The action button confirms with a green checkmark before turning into **Show in Finder**. **Create new symlink** clears both selections. The equally tall circular **×** immediately to the right of **Show in Finder** instead returns to the selected source and destination tiles. Both actions leave the created link and its source on disk. A duplicate-name warning temporarily occupies the action button, then crossfades back to **Create symlink** after six seconds. The tiles remain editable throughout. Every retry revalidates the paths and never overwrites an existing item.

## Selecting and dropping

- Click a tile for the native file picker, or drop one Finder item onto it. Source accepts a file, folder or package; destination accepts a folder, including a symbolic link to a folder.
- Picker and drop input share asynchronous validation. Canceling or rejecting input preserves the previous valid selection; the latest request for a tile wins.
- Right-click a selected tile to change or clear it, reveal it in Finder, or copy its full path. Tooltips and VoiceOver expose the full path even when the filename is shortened.
- The editor keeps just the two tiles and buttons, without path rows or tile captions. Unavailable locations and creation failures show feedback within the existing button row; selections stay editable.
- A selected alias or symbolic link remains the selected source; it is not silently replaced with its target. Broken source links are rejected. Existing output items, including broken links, are never replaced.
- **Copy path** and the animation playground's **Copy settings** use the host's `clipboard-write` permission and only copy after an explicit click. Symlinker does not read clipboard history.

## Shelf and navigation

The paired widget shows the current status, source and destination, a Continue action, and Finder reveal when a result is available. Its source and destination rows also accept Finder drops. The full two-tile editor remains a separate composition.

Home, close and reopening preserve the current in-memory session. Duplicate editor requests are ignored. The full two-tile widget opened from its icon stays open for dragging files, releasing its hold on Home, close or deactivation. The compact shelf widget holds only during picking, loading and creation; enabling Symlinker alone does not pin the shelf open. Leaving during the confirmation animation settles the already-created result instead of losing it.

The separate expanded editor also disables automatic collapse while it is open. Host close/swipe controls still work, and the compact shelf widget keeps its usual auto-collapse behavior.

Selections are not saved across app launches. Access leases are replaced per tile and released on reset or deactivation. An already-running filesystem syscall may finish after deactivation; it retains its access until it finishes, but cannot publish stale UI updates. No operation deletes existing links or their sources.

## Install locally

For the latest local changes, build and install `.build/Symlinker.droplet` into Droppy Playground. [dist/Symlinker.zip](dist/Symlinker.zip) is a separately packaged release archive; development builds do not refresh it automatically. Local development bundles are unsigned.

## Developing

This package uses the installed SDK at `/Users/dani/droppykit`. Update that dependency in `Package.swift` on another Mac. Run `droppykit update` to fast-forward a clean SDK checkout using the official updater; this local-path dependency uses the updated checkout directly. See [COMPATIBILITY.md](COMPATIBILITY.md) for the exact nightly host and public SDK used for verification.

```sh
droppykit build
droppykit validate
droppykit run -- --shots ./shots-symlinker/idle --report ./shots-symlinker/idle/report.json
swift test
```

Build distributables with `droppykit build` to link Droppy's resilient SDK. The icon's scaffold blue has been replaced with neutral gray. Creator metadata and avatar remain placeholders for local development.

Preview states are supported by the debug harness through `SYMLINKER_PREVIEW_STATE` and `SYMLINKER_PREVIEW_DIRECTORY`; they never create a link. States include `source`, `destination`, `ready`, `mitosis`, `snapped`, `rebound`, `confirmed`, `success`, `returned` (after pressing ×), `conflict`, `conflict-faded`, `checking`, and `error`. Append `:reduced` to exercise Reduce Motion. New stability screenshots and reports live under `shots/stability/`.

## Animation playground

Right-click the Symlinker panel and choose **Animation playground…**, or open it from the shelf widget settings or Symlinker settings pane. Replay uses a separate demo model and never creates files or links. Loop previews continuously; scrub inspects a frame; Reduce Motion previews stationary tiles and the progress track.

Each phase has its own duration: stretch, split, recoil, settle, checkmark transition, and Finder transition. The tile sequence total is the sum of the first four; button transitions overlap the tile sequence. Tune blur, rebound, damping, squash, split softness, and trails with sliders or exact numeric fields. Changes apply on the next replay, persist across launches, and also apply to real links. **Copy settings** copies a readable summary to share; **Reset defaults** restores the factory preset. The preview uses the same layout metrics as the real editor, and its controls scroll at smaller window heights.
