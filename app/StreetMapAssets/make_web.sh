#!/bin/bash
# The street map's page engine and styles (plan phase 9; the web engine, owner 2026-10-14): MapLibre GL JS, PMTiles JS
# and Protomaps' style maker at the pinned versions below, copied into web/ and the light and dark styles made from
# them, every address the app's own (prepareme-map://), so neither the app nor its build ever fetches anything. Run by
# hand only to move to newer versions, and say so in README.md; then rebuild and try the street map on the simulator
# again (the engine trial, app/MapTrial, was removed 2026-10-15; git history before then has it).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MAPLIBRE=maplibre-gl@6.11.2
PMTILES=pmtiles@4.5.0
BASEMAPS=@protomaps/basemaps@5.7.2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(cd "$work" && npm install --silent --ignore-scripts --no-audit --no-fund --no-save "$MAPLIBRE" "$PMTILES" "$BASEMAPS")
dist="$work/node_modules/maplibre-gl/dist"
cp "$dist"/{maplibre-gl.mjs,maplibre-gl-shared.mjs,maplibre-gl-worker.mjs,maplibre-gl.css} "$HERE/web/"
cp "$work/node_modules/maplibre-gl/LICENSE.txt" "$HERE/web/LICENSE-maplibre-gl.txt"
cp "$work/node_modules/pmtiles/dist/pmtiles.js" "$HERE/web/"
cat > "$work/style.mjs" <<'JS'
import { writeFileSync } from "node:fs";
import { layers, namedFlavor } from "@protomaps/basemaps";
for (const flavor of ["light", "dark"]) {
  const style = {
    version: 8,
    glyphs: "prepareme-map://app/fonts/{fontstack}/{range}.pbf",
    sprite: `prepareme-map://app/sprites/v4/${flavor}`,
    sources: {
      protomaps: {
        type: "vector",
        url: "pmtiles://prepareme-map://tiles/street.pmtiles",
        attribution: "© OpenStreetMap contributors",
      },
    },
    layers: layers("protomaps", namedFlavor(flavor), { lang: "en" }),
  };
  // Side streets' names are in the map file from zoom 14, but Protomaps' style shows them only from 15 (owner,
  // 2026-10-14: "plenty of space to label them").
  const minor = style.layers.find((layer) => layer.id === "roads_labels_minor");
  if (!minor) throw new Error("the style has no roads_labels_minor layer");
  minor.minzoom = 14;
  writeFileSync(process.argv[2] + `/style-${flavor}.json`, JSON.stringify(style));
}
JS
(cd "$work" && node style.mjs "$HERE/web")
echo "web/ made from $MAPLIBRE, $PMTILES and $BASEMAPS"
