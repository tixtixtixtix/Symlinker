# Symlinker

A native SwiftUI droplet for Droppy. The idle view contains two file tiles and a detached rounded progress track, inside the host's standard notch width. No title or instructional footer is shown.

Click or drop one source file/folder and one destination folder. **Create Symlink** appears when both are selected. Existing files and links, including broken links, are never overwritten.

The creation animation dissolves the destination, overlaps the original and duplicate, stretches across both tiles, and splits into two rounded rectangles. An elapsed-time clock, independent of button transitions, drives staggered spring recoil, tall and skinny rebound, restrained motion trails, and blur that resolves to sharp resting tiles. The badge and track appear during the settle; the action label blurs and slides through confirmation into Show in Finder. With Reduce Motion, the tiles remain still and the center track fills instead.

The action button confirms with a green checkmark before turning into **Show in Finder**. **Create new symlink**, at bottom left, clears the current selection and leaves the created link on disk.

## Install locally

The current prebuilt bundle is in [dist/Symlinker.zip](dist/Symlinker.zip). Extract it and install `Symlinker.droplet` into Droppy Playground. This is an unsigned local development build.

## Developing

This package uses the installed SDK at `/Users/dani/droppykit`. Update that dependency in `Package.swift` on another Mac, or use the public DroppyKit repository with `from: "1.8.0"`.

```sh
droppykit build
droppykit validate
droppykit run -- --shots ./shots-symlinker/idle --report ./shots-symlinker/idle/report.json
swift test
```

Build distributables with `droppykit build` to link Droppy's resilient SDK. The icon's scaffold blue has been replaced with neutral gray. Creator metadata and avatar remain placeholders for local development.

Preview states are supported by the debug harness through `SYMLINKER_PREVIEW_STATE` and `SYMLINKER_PREVIEW_DIRECTORY`; they never create a link. States include `source`, `ready`, `mitosis`, `snapped`, `rebound`, `confirmed`, `success`, and `error`.

## Animation playground

Right-click the Symlinker panel and choose **Animation playground…**, or open it from the shelf widget settings or Symlinker settings pane. Replay uses a separate demo model and never creates files or links. Loop previews continuously; scrub inspects a frame; Reduce Motion previews stationary tiles and the progress track.

Each phase has its own duration: stretch, split, recoil, settle, checkmark transition, and Finder transition. The tile sequence total is the sum of the first four; button transitions overlap the tile sequence. Tune blur, rebound, damping, squash, split softness, and trails with sliders or exact numeric fields. Changes apply on the next replay, persist across launches, and also apply to real links. **Copy settings** copies a readable summary to share; **Reset defaults** restores the selected 0.88-second sequence.
