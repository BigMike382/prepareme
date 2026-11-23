// The street map's files as one source (combined step 9, the travel maps; ours, like streetmap.js). With a travel map
// on the phone, the page reads the home file first, then each travel map, and takes each tile from the first file
// that holds it: where the home file and a travel map overlap, the home file's tile is drawn and the travel map's is
// never read. One source, so MapLibre places each road and name once, never twice from two files (two sources would
// draw both). Every tile in a file is the build's whole tile, so a home tile beside a travel tile joins it with no gap.
// A classic script, so the app's tests run it in JavaScriptCore with made-up files (TravelMapsTests).
var pmStack = {
  // `archives`: pmtiles.PMTiles (or anything with its getZxy), the home file first. A tile no file holds is empty.
  async tile(archives, z, x, y, signal) {
    for (const archive of archives) {
      const found = await archive.getZxy(z, x, y, signal);
      if (found) return new Uint8Array(found.data);
    }
    return new Uint8Array();
  },
  // MapLibre's protocol for "pmstack://{z}/{x}/{y}".
  protocol(archives) {
    return async (params, abort) => {
      const m = /^pmstack:\/\/(\d+)\/(\d+)\/(\d+)$/.exec(params.url);
      if (!m) throw new Error("not a street map tile address: " + params.url);
      return { data: await pmStack.tile(archives, +m[1], +m[2], +m[3], abort && abort.signal) };
    };
  },
  // The style's one source, read through the stack: the files' area together and their deepest zoom; its credit kept.
  source(base, bounds, maxzoom) {
    const out = { type: "vector", tiles: ["pmstack://{z}/{x}/{y}"], minzoom: 0, maxzoom, bounds };
    if (base && base.attribution) out.attribution = base.attribution;
    return out;
  },
};
