# Street map lettering and icons

The street map's fonts and icons (build plan phase 9), kept here so the app never fetches them (owner, 2026-10-14:
a copy in the project, not a live source). Both engines and every device use this copy.

- From protomaps/basemaps-assets at commit `028c18f713baecad011301ff7a69acc39bcc2ae7` (2026-10-14).
- `fonts/`: Noto Sans Regular, Medium and Italic, the three the Protomaps style names, in MapLibre's glyph files
  (one per block of 256 characters), every block, 0 to 65535 (13 MB). Until 2026-10-14 only 8 blocks were kept, on
  the belief that a character in another block would just draw nothing; on the native engine a name needing a
  missing block stopped the lettering of its whole map piece (roads included) and the map never settled (F-074), so
  never trim them again. Licence: SIL Open Font License 1.1 (`fonts/OFL.txt`),
  which allows bundling with software.
- `sprites/v4/`: the light and dark styles' icons (road shields, places), at 1x and 2x. Derived from Mapzen's
  tangrams/icons, MIT licence (`sprites/LICENSE-tangrams-icons.txt`, whose notice must stay with them).
- Never changed by hand: to update, fetch the same files at a newer commit and say so in this file.
- `web/` (phase 9's screens, the web engine, owner 2026-10-14): the street map page (`streetmap.html`,
  `streetmap.js` and, since the travel maps of combined step 9, `stack.js`, ours), MapLibre GL JS 6.11.2 (BSD-3,
  `LICENSE-maplibre-gl.txt`), PMTiles 4.5.0 (BSD-3, `LICENSE-pmtiles.txt`) and the light and dark styles made with Protomaps' style maker 5.7.2 (BSD-3,
  `LICENSE-protomaps-basemaps.md`), all made by `make_web.sh` at those pinned versions; the licence texts are each
  project's own, fetched from its repository on 2026-10-14. Never changed by hand except our page files.
