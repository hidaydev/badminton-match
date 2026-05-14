# Instagram Post Feature — Design Spec

**Date:** 2026-05-14

## Overview

A new "Instagram Post" menu item on the home page that lets users create a branded Instagram post by uploading a photo, which is composited with template overlay images (header/footer PNGs) and optional date text. The result is downloaded as a high-resolution PNG.

---

## User Flow

1. User taps **Instagram Post** on the home page.
2. User taps the upload area to select a photo from their device.
3. The photo appears behind the template overlays in a live canvas preview.
4. User drags the preview to reposition the photo.
5. User taps **Download** — a 1080×1350px PNG is generated and auto-downloaded.

---

## Template System

A template is a plain config object that defines the canvas format and its layers:

```ts
interface PostTemplate {
  id: string
  label: string          // e.g. "Portrait 4:5"
  width: number          // canvas px (e.g. 1080)
  height: number         // canvas px (e.g. 1350)
  header?: string        // path to header PNG asset (optional)
  footer?: string        // path to footer PNG asset (optional)
  datePosition?: {       // where to render date text (optional)
    x: number
    y: number
    fontSize: number
    color: string
  }
}
```

Templates are defined as a static array in the source. No server or database needed.

**v1 template (portrait):**
- Format: 4:5 (1080×1350)
- Header: none
- Footer: `test.png` ("Main Aja Dulu!" banner, full-width at bottom)
- Date: none

Future templates (square, different branding, with date) are added by extending this array and dropping in new PNG assets.

---

## Canvas Compositing (Layer Order)

Layers drawn bottom → top on an HTML5 Canvas:

| Layer | Content | Notes |
|---|---|---|
| 1 | User photo | Cover-fill, offset by drag XY |
| 2 | Header PNG | Full-width at top, from template config |
| 3 | Footer PNG | Full-width at bottom, from template config |
| 4 | Date text | Rendered at template-defined position (future) |

The canvas is always rendered at full resolution (1080×1350). The on-screen preview is a scaled-down CSS version of the same canvas.

---

## Photo Repositioning

- Mouse drag and touch drag both update a `photoOffset: {x, y}` state value.
- On each drag delta, the canvas is redrawn with the new offset.
- Initial position: photo centered on the canvas (cover-fill).
- Bounds: no clamping — user can pan freely.

---

## Download

- Only enabled after a photo is uploaded.
- `canvas.toBlob('image/png')` → creates an object URL → triggers `<a download>` click → revokes URL.
- Output filename: `majadu-post.png`.

---

## Routing & Navigation

- New route: `/instagram-post` under `HomeLayout`.
- New page component: `src/pages/InstagramPostPage.tsx`.
- New menu item added to `HomePage.tsx`:
  - Icon: 📸
  - Label: Instagram Post
  - Description: Create a post from template

---

## Assets

- Footer image: `src/assets/instagram/footer.png` (copy of `test.png`).
- Template config: `src/config/instagramTemplates.ts`.

---

## Out of Scope (v1)

- Date picker / date text rendering (future template enhancement)
- Header image (future)
- Multiple template selection UI (future — only one template in v1)
- Server-side processing
- Cloud upload or sharing
