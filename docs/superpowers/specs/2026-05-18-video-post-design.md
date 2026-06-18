# Video Post — Design Spec

**Date:** 2026-05-18

## Summary

A new page (`/video-post`) that lets users overlay the Majadu branding (header band + footer PNG) on top of a user-uploaded video and export it as an MP4 file. It is a video equivalent of the existing Instagram Post page, without any photo editing controls.

## Scope

- New home menu entry: "Video Post" (alongside the existing "Instagram Post" entry)
- New page: `src/pages/VideoPostPage.tsx`
- New route: `/video-post` added to `src/App.tsx`
- New dependency: `mp4-muxer` for MP4 export

## Out of Scope

- No drag/pan/zoom/trim controls on the video
- No date graphic overlay
- No leaderboard overlay
- No post vs. story format picker (single output: native video size with overlays)
- No server-side processing

## UI

Mirrors the existing `InstagramPostPage` pattern exactly, optimised for mobile:

**State 1 — No video uploaded:**
- Full-width canvas (aspect-ratio 9:16) fills the screen below the header
- Overlay of header band and footer PNG visible on the blank canvas
- Tap anywhere on the canvas to trigger the hidden file input

**State 2 — Video loaded:**
- Video plays on the canvas under the header/footer overlays
- Two small icon buttons in the top-right corner of the canvas (same as photo post):
  - Swap button (↺) — re-open file picker
  - Export button (⬇, yellow circle) — starts recording

**Export state:**
- Export button shows a spinner + disabled state while recording
- No bottom sheet, no format picker
- When video ends, recording stops automatically and MP4 is downloaded

## Technical Design

### Canvas rendering loop

```
HTMLVideoElement (hidden, autoplay, muted during preview)
  └─ requestAnimationFrame loop
       ├─ ctx.drawImage(videoElement, 0, 0, W, H)   // cover-fill to canvas
       ├─ drawHeader(ctx, W, overlays.logo)           // existing function reused
       └─ ctx.drawImage(overlays.footer, ...)         // existing footer draw reused
```

Canvas dimensions match the uploaded video's native width/height (e.g. 1080×1920 for a 9:16 phone video).

### Export pipeline

`mp4-muxer` uses the browser's **WebCodecs API** (`VideoEncoder` / `AudioEncoder`), not MediaRecorder. Supported on iOS Safari 17+ and Android Chrome 94+.

1. User taps export → video rewinds to start, playback begins
2. `mp4-muxer` is initialised with an `ArrayBufferTarget` and the video's width/height/fps
3. A `VideoEncoder` is created; each canvas frame is captured via `ImageBitmap` from the canvas and passed to the encoder on the RAF loop
4. An `AudioEncoder` captures audio from `videoElement` via a `MediaStreamAudioSourceNode` → `AudioWorklet` pipeline
5. Encoded video and audio chunks are fed to the muxer
6. `videoElement.onended` → encoders flushed → muxer finalised → `ArrayBuffer` wrapped in a Blob and downloaded as `majadu-video-<date>.mp4`

If WebCodecs is not available (older browsers), fall back to `MediaRecorder` with `video/mp4` mime type preference, then `video/webm`.

### Overlay images

Reuse the same `TEMPLATE` constant from `instagramTemplates.ts`. Load `logo` and `footer` images via the existing `loadImage()` helper. The header band is drawn programmatically (reuse `drawHeader()`). No brush stroke, chevrons, or story background needed.

### File input

```html
<input type="file" accept="video/*" />
```

On change: create object URL → set as `videoElement.src` → wait for `loadedmetadata` → set canvas dimensions to `videoElement.videoWidth × videoElement.videoHeight` → start RAF loop.

## Files Changed

| File | Change |
|------|--------|
| `src/pages/VideoPostPage.tsx` | New page |
| `src/App.tsx` | Add `/video-post` route under `HomeLayout` |
| `src/pages/HomePage.tsx` | Add "Video Post" menu entry |
| `package.json` / `yarn.lock` | Add `mp4-muxer` |

## Dependencies

- `mp4-muxer` — pure TypeScript MP4 muxer, no native dependencies (~50KB)
