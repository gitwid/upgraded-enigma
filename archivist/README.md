# Personal Data Archivist (PDA)

A local-first vessel for **your own** content: transient feed → persistent,
addressable, searchable archive. No servers, no build step, no accounts, no
model that phones home. Three plain files and a static page.

The design principle: **decouple content from its delivery mechanism.** A feed
is a temporal flow; this makes it a *coordinate map*. Every entry is reachable
(`#id`), queryable, and linked back to its origin.

## The pieces

| File | Role |
| --- | --- |
| `schema/entry.schema.json` | The shape of one archived unit — the stable coordinate. |
| `capture/capture.js` | Passive DOM transcription. Reads posts you're already viewing; never scrapes, scrolls, or spoofs. |
| `taxonomy.json` | **Your ontology.** Concepts and the terms they "radiate" through. This is the searchable soul of the system — edit it constantly. |
| `archive.json` | Your entries. Ships with a few samples; replace with your export. |
| `archive.html` | The long-form vertical page: search, taxonomy expansion, tag filters, permalinks. Open it in a browser. |

## How search delivers "fractal → mathematical images" and "queer → everything associated"

There are no ML embeddings here, and that's deliberate — they'd add weight,
drift, and a dependency you don't control. Instead, **you** define meaning in
`taxonomy.json`:

```json
"fractal": { "radiates": ["mandelbrot", "self-similar", "recursion", "geometry", ...] }
```

A search for `fractal` then also matches posts tagged or captioned
`mandelbrot`, `self-similar`, `geometry`, and so on — the page shows you exactly
what your query radiated into. `queer` works the same way, but that list is
hand-curated on purpose: no model knows what "previously associated with
queerness" means in *your* history. You do. Grow the list as your archive grows.

> When you later want true image-content search (finding fractal-*looking*
> images with no matching words), the slot is clean: compute CLIP embeddings per
> entry, store them in the record, and add a nearest-neighbour pass alongside
> the term match. The schema and UI don't have to change.

## Workflow

1. **Capture.** On a page showing your Instagram posts, open DevTools → Console,
   paste the contents of `capture/capture.js`, then run `PDA.capture()`.
   Scroll, capture again as needed (it deduplicates by post shortcode).
   - Or make a bookmarklet: minify `capture.js` and prefix with `javascript:`.
2. **Export.** Run `PDA.export()` → downloads `archive.json`. Drop it next to
   `archive.html` (replacing the sample).
3. **Classify.** Add `tags` to entries using vocabulary from `taxonomy.json`
   (`queer`, `fractal`, `mathematical-aesthetics`, …). Capture keeps your tags
   on re-capture, so this enrichment is durable.
4. **Read & search.** Open `archive.html`. Type a concept; filter by tag chips;
   click any entry's `#id` for a stable link; click `source ↗` to return to origin.

If your browser blocks `fetch` of local files (`file://`), the page shows a
drop zone — drag `archive.json` onto it, or serve the folder:
`python3 -m http.server` and visit `http://localhost:8000/archivist/archive.html`.

## Boundaries (the honest part)

- This captures **your own** content that **you** are viewing while logged in.
  It is a personal archiving aid, not a crawler. Automated *collection* of
  Instagram data can conflict with their Terms; the most robust and clearly
  legitimate source of your history is Instagram's own **"Download Your
  Information"** export — the schema here ingests that just as happily as
  console capture.
- Media URLs from capture are volatile (they expire). For a truly non-volatile
  archive, download the media and set `media[].local` to the saved path.

## Roadmap

- [ ] Ingest adapter for the official "Download Your Information" ZIP.
- [ ] `media[].local` downloader for non-volatile media.
- [ ] Optional CLIP embedding pass for content-based image search.
- [ ] Video: frame sampling + optional audio transcript into the haystack.
