// PrepareMe's street map page (plan phase 9; the web engine, owner 2026-10-14). The app starts it with pm.start and
// hands it everything it draws; the page never reads the position or anything else itself, and asks nothing of the
// internet. Messages back to the app go through the "map" handler: ready, camera (after each move), tap, drag (the
// person moved the map, which ends Follow me), health (every
// 5 seconds, for the app's watchdog: iOS can end WebKit's helpers in the background and leave the map loading nothing,
// maplibre-gl-js #8461 and #8780; the app then reloads the page where it was), and error.
import * as gl from "./maplibre-gl.mjs";

const say = (kind, data = {}) => {
  try { webkit.messageHandlers.map.postMessage({ kind, ...data }); } catch (e) { /* not in the app: a test page */ }
};
window.onerror = (message, source, line) => say("error", { message: String(message), at: `${source}:${line}` });
window.addEventListener("unhandledrejection", (e) => say("error", { message: String(e.reason) }));

// The overlays, drawn over Protomaps' layers in this order (later on top). Colors are the app's: road closures red,
// river gauges blue, storm warnings outlined amber (owner, 2026-10-14), rally points and routes green, the phone's own
// pins orange, the position blue (gray once the fix is half a minute old: Position.Freshness). Anything `old` (over 8 hours, MapConditions.oldAfter) is dimmed. On paper (the Mac's
// printed map) the rally points are white circles edged in black with their legend numbers, and the routes are edged
// in black, so they read on a black-and-white printer (remaining-findings plan, Task 11.6; F29: green on grey). The
// Start point, where the printed turn lists begin (hand-off improvements, phase 3), is a smaller dot in the text
// color, edged in the ground's, on paper black edged in white.
const EMPTY = { type: "FeatureCollection", features: [] };
const SOURCES = ["conditions", "marks", "pins", "draft", "position"];
// An old fix's dot and circle in the project's text2 gray (the street map fixes plan, task 1.1).
const STALE = (live) => ["case", ["==", ["get", "stale"], true], "#8a8f98", live];
const dim = (full) => ["case", ["==", ["get", "old"], true], full * 0.35, full];
const LABEL = { "text-font": ["Noto Sans Medium"], "text-size": 13, "text-offset": [0, 1.2], "text-anchor": "top",
                "text-optional": true };
const HALO = (dark) => ({ "text-halo-color": dark ? "#1d1f23" : "#ffffff", "text-halo-width": 1.5,
                          "text-color": dark ? "#f2f2f2" : "#1d1f23" });

function overlays(dark, paper) {
  const night = red && !paper;  // paper is never red
  return [
    { id: "pm-warning-fill", type: "fill", source: "conditions", filter: ["==", ["get", "kind"], "warning"],
      paint: { "fill-color": "#f2a900", "fill-opacity": dim(0.12) } },
    { id: "pm-warning-line", type: "line", source: "conditions", filter: ["==", ["get", "kind"], "warning"],
      paint: { "line-color": "#d48a00", "line-width": 3, "line-opacity": dim(1) } },
    { id: "pm-road-line", type: "line", source: "conditions",
      filter: ["all", ["==", ["geometry-type"], "LineString"], ["in", ["get", "kind"], ["literal", ["closure", "road"]]]],
      paint: { "line-color": ["case", ["==", ["get", "kind"], "closure"], "#d0021b", "#e8590c"], "line-width": 5,
               "line-opacity": dim(0.9) } },
    { id: "pm-road-point", type: "circle", source: "conditions",
      filter: ["all", ["==", ["geometry-type"], "Point"], ["in", ["get", "kind"], ["literal", ["closure", "road"]]]],
      paint: { "circle-radius": 7, "circle-color": ["case", ["==", ["get", "kind"], "closure"], "#d0021b", "#e8590c"],
               "circle-stroke-color": "#ffffff", "circle-stroke-width": 2, "circle-opacity": dim(1),
               "circle-stroke-opacity": dim(1) } },
    { id: "pm-gauge", type: "circle", source: "conditions",
      filter: ["in", ["get", "kind"], ["literal", ["gauge", "gauge-flood"]]],
      paint: { "circle-radius": ["case", ["==", ["get", "kind"], "gauge-flood"], 9, 7], "circle-color": "#1971c2",
               "circle-stroke-color": ["case", ["==", ["get", "kind"], "gauge-flood"], "#d0021b", "#ffffff"],
               "circle-stroke-width": 2.5, "circle-opacity": dim(1), "circle-stroke-opacity": dim(1) } },
    ...(paper ? [{ id: "pm-route-edge", type: "line", source: "marks", filter: ["==", ["get", "kind"], "route"],
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#000000", "line-width": 9 } }] : []),
    { id: "pm-route", type: "line", source: "marks", filter: ["==", ["get", "kind"], "route"],
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#2b8a3e", "line-width": 5, "line-opacity": 0.85,
               // the alternate route dashed, so the two read apart (street map fixes plan, task 2.2); [1, 0] is solid
               "line-dasharray": ["case", ["==", ["get", "route"], "alternate-route"], ["literal", [2, 1.5]],
                                  ["literal", [1, 0]]] } },
    { id: "pm-route-label", type: "symbol", source: "marks", filter: ["==", ["get", "kind"], "route"],
      layout: { "symbol-placement": "line", "text-field": ["get", "name"], "text-font": ["Noto Sans Medium"],
                // repeated less often and kept apart, so route and rally point names part (task 5.2)
                "text-size": 13, "symbol-spacing": 400, "text-padding": 6 },
      paint: HALO(dark) },
    { id: "pm-draft", type: "line", source: "draft",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#2b8a3e", "line-width": 4, "line-dasharray": [1.5, 1] } },
    { id: "pm-draft-point", type: "circle", source: "draft", filter: ["==", ["geometry-type"], "Point"],
      paint: { "circle-radius": 5, "circle-color": "#2b8a3e", "circle-stroke-color": "#ffffff",
               "circle-stroke-width": 2 } },
    // Each kind in its BASE color with its own symbol on top (street map fixes plan, task 3.2): the symbols are the
    // app's SF Symbols, drawn by the app and handed over in pm.start (pinIcons), so the shape tells kinds apart in red
    // night too.
    // Red night (the W9 review): the red and amber kinds' symbols dark on their dots, danger's dot white, and every
    // pin's word kept even where pins crowd; the app picks each kind's night look (PersonalPins.Label.nightIcon).
    { id: "pm-pin", type: "circle", source: "pins",
      paint: { "circle-radius": 11,
               "circle-color": ["coalesce", ["get", night ? "nightColor" : "color"], ["get", "color"], "#b45309"],
               "circle-stroke-color": "#ffffff", "circle-stroke-width": 2 } },
    { id: "pm-pin-icon", type: "symbol", source: "pins",
      // a shared pin names its own picture (`icon`: its symbol's); a phone's own from before goes by its kind's word
      layout: { "icon-image": night ? ["coalesce", ["get", "nightIcon"], ["get", "icon"], ["concat", "pm-pin-", ["get", "label"]]]
                                    : ["coalesce", ["get", "icon"], ["concat", "pm-pin-", ["get", "label"]]],
                "icon-allow-overlap": true, "icon-ignore-placement": true } },
    { id: "pm-pin-label", type: "symbol", source: "pins",
      layout: { ...LABEL, "text-field": ["get", "label"], "text-size": 12, "text-offset": [0, 1.5],
                ...(night ? { "text-optional": false, "text-allow-overlap": true, "text-ignore-placement": true } : {}) },
      paint: HALO(dark) },
    { id: "pm-rally", type: "circle", source: "marks", filter: ["==", ["get", "kind"], "rally"],
      paint: paper ? { "circle-radius": 12, "circle-color": "#ffffff", "circle-stroke-color": "#000000",
                       "circle-stroke-width": 3 }
                   : { "circle-radius": 13, "circle-color": "#2b8a3e", "circle-stroke-color": "#ffffff",
                       "circle-stroke-width": 3 } },
    // On screen a meeting place is a green flag pin, larger than a pin (the map pins plan, Task 2.6); paper keeps its
    // numbered circles. The flag is the app's white flag.fill, handed over with the pins' pictures.
    ...(paper ? [] : [{ id: "pm-rally-icon", type: "symbol", source: "marks", filter: ["==", ["get", "kind"], "rally"],
      layout: { "icon-image": "pm-pin-flag.fill", "icon-allow-overlap": true, "icon-ignore-placement": true } }]),
    ...(paper ? [{ id: "pm-rally-number", type: "symbol", source: "marks", filter: ["has", "number"],
      layout: { "text-font": LABEL["text-font"], "text-size": 14, "text-field": ["to-string", ["get", "number"]],
                "text-allow-overlap": true, "text-ignore-placement": true },
      paint: { "text-color": "#000000" } }] : []),
    { id: "pm-start", type: "circle", source: "marks", filter: ["==", ["get", "kind"], "start"],
      paint: { "circle-radius": 8, "circle-color": paper ? "#000000" : dark ? "#f2f2f2" : "#1d1f23",
               "circle-stroke-color": paper || !dark ? "#ffffff" : "#1d1f23", "circle-stroke-width": 3 } },
    { id: "pm-rally-label", type: "symbol", source: "marks", filter: ["in", ["get", "kind"], ["literal", ["rally", "start"]]],
      // Each name tries below, above, then beside its dot, so names close together part rather than pile up (a
      // stress test, 2026-10-14); above the base map's own labels, it wins over them.
      layout: { "text-font": LABEL["text-font"], "text-size": 13, "text-field": ["get", "name"],
                "text-variable-anchor": ["top", "bottom", "left", "right"], "text-radial-offset": 1.2,
                "text-justify": "auto", "text-allow-overlap": false },
      paint: HALO(dark) },
    { id: "pm-accuracy", type: "circle", source: "position", filter: ["==", ["get", "part"], "dot"],
      paint: { "circle-radius": ["get", "accuracyPixels"], "circle-color": STALE("#1c7ed6"), "circle-opacity": 0.12,
               "circle-pitch-alignment": "map" } },
    { id: "pm-heading", type: "symbol", source: "position", filter: ["has", "heading"],
      layout: { "icon-image": "pm-heading", "icon-rotate": ["get", "heading"], "icon-rotation-alignment": "map",
                "icon-allow-overlap": true, "icon-ignore-placement": true } },
    { id: "pm-position", type: "circle", source: "position", filter: ["==", ["get", "part"], "dot"],
      paint: { "circle-radius": 8, "circle-color": STALE("#1c7ed6"), "circle-stroke-color": "#ffffff",
               "circle-stroke-width": 3 } },
  ];
}

// The heading's cone, drawn once as an image (no network, no sprite of its own).
function headingImage() {
  const size = 64, c = document.createElement("canvas");
  c.width = c.height = size;
  const g = c.getContext("2d");
  const grad = g.createLinearGradient(size / 2, size / 2, size / 2, 0);
  grad.addColorStop(0, "rgba(28,126,214,0.55)");
  grad.addColorStop(1, "rgba(28,126,214,0)");
  g.fillStyle = grad;
  g.beginPath();
  g.moveTo(size / 2, size / 2);
  g.arc(size / 2, size / 2, size / 2, -Math.PI / 2 - 0.45, -Math.PI / 2 + 0.45);
  g.closePath();
  g.fill();
  return g.getImageData(0, 0, size, size);
}

// The age line as the credits' HTML: the words escaped, the color only from the app (a "#rrggbb").
function ageLine({ words, color }) {
  const span = document.createElement("span");
  span.textContent = words;
  if (/^#[0-9a-f]{6}$/.test(color)) { span.style.color = color; span.style.fontWeight = "600"; }
  return span.outerHTML;
}

let map = null, dark = false, red = false, styles = {}, data = Object.fromEntries(SOURCES.map((s) => [s, EMPTY]));
let position = null;  // {lat, lon, accuracy, heading, stale}
let pinImages = {};  // "pm-pin-Water": its decoded symbol, kept to add back after a style change

function withOverlays(base, paper = false) {
  const style = structuredClone(base);
  for (const name of SOURCES) style.sources[name] = { type: "geojson", data: data[name] };
  style.layers.push(...overlays(paper ? false : dark, paper));  // paper's labels are dark on white
  return style;
}

// The accuracy circle's size in pixels at the current zoom (meters per pixel at the position's latitude); an old fix's
// is never under 24 pixels, so it reads as "about here" rather than a point.
function positionData() {
  if (!position || !map) return EMPTY;
  const metersPerPixel = 156543.03392 * Math.cos(position.lat * Math.PI / 180) / Math.pow(2, map.getZoom());
  const floor = position.stale ? 24 : 8;
  const props = { part: "dot", stale: position.stale,
                  accuracyPixels: Math.min(Math.max(position.accuracy / metersPerPixel, floor), 400) };
  if (Number.isFinite(position.heading)) props.heading = position.heading;
  return { type: "FeatureCollection", features: [
    { type: "Feature", geometry: { type: "Point", coordinates: [position.lon, position.lat] }, properties: props }] };
}

function put(name, json) {
  data[name] = json;
  map?.getSource(name)?.setData(json);
}

function camera() {
  const c = map.getCenter();
  return { longitude: c.lng, latitude: c.lat, zoom: map.getZoom(), bearing: map.getBearing(), pitch: map.getPitch() };
}

// What the app calls. Each takes plain numbers or GeoJSON objects; none returns anything the app waits on.
window.pm = {
  async start({ dark: night = false, longitude, latitude, zoom, bearing = 0, pitch = 0, bounds, maxZoom = 18,
                printable = false, files = [], tileMaxZoom = 15, pinIcons = {}, age = null, red: redOn = false }) {
    dark = night;
    red = redOn;
    const protocol = new pmtiles.Protocol();
    gl.addProtocol("pmtiles", protocol.tile);
    // With travel maps (combined step 9), the home file and each travel map are one source, each tile from the first
    // file that holds it (stack.js), so nothing is drawn twice; the home file alone keeps the style's own source.
    const stacked = files.length > 1;
    if (stacked) {
      gl.addProtocol("pmstack", pmStack.protocol(files.map((file) => new pmtiles.PMTiles(file))));
    }
    gl.setWorkerUrl(new URL("maplibre-gl-worker.mjs", location.href).href);  // its worker only finds itself on http
    for (const flavor of ["light", "dark"]) {
      styles[flavor] = await (await fetch(`prepareme-map://app/web/style-${flavor}.json`)).json();
      const sources = styles[flavor].sources;
      if (stacked) sources.protomaps = pmStack.source(sources.protomaps, bounds, tileMaxZoom);
    }
    map = new gl.Map({
      container: "map", style: withOverlays(styles[dark ? "dark" : "light"]), center: [longitude, latitude], zoom,
      bearing, pitch, maxZoom, maxBounds: bounds ? [[bounds[0] - 1, bounds[1] - 1], [bounds[2] + 1, bounds[3] + 1]] : undefined,
      // the map's age beside its credits (street map fixes plan, task 3.5), amber once old; the app's own words
      attributionControl: { compact: false, customAttribution: age ? ageLine(age) : undefined },
      dragRotate: true, touchPitch: false,
      // the Mac's printed household map reads the drawn picture back (snapshot): kept only where it is printed
      canvasContextAttributes: printable ? { preserveDrawingBuffer: true } : undefined,
    });
    const decoded = Promise.all(Object.entries(pinIcons).map(async ([id, url]) => {
      const img = new Image();
      img.src = url;
      try { await img.decode(); pinImages[id] = img; } catch { /* that kind shows its color alone */ }
    }));
    const addPin = (id) => { if (pinImages[id] && !map.hasImage(id)) map.addImage(id, pinImages[id], { pixelRatio: 3 }); };
    map.on("styleimagemissing", (e) => {
      if (e.id === "pm-heading") map.addImage("pm-heading", headingImage());
      else addPin(e.id);
    });
    map.on("load", async () => {
      map.addImage("pm-heading", headingImage());
      await decoded;
      Object.keys(pinImages).forEach(addPin);
      say("ready");
    });
    map.on("error", (e) => say("error", { message: String(e.error?.message ?? e.error) }));
    map.on("moveend", () => say("camera", camera()));
    map.on("dragstart", () => say("drag"));  // only a finger or the pointer drags; the app's own moves never do
    map.on("zoom", () => { if (position) map.getSource("position")?.setData(positionData()); });
    const tap = (e, longPress) => {
      const near = map.queryRenderedFeatures([[e.point.x - 12, e.point.y - 12], [e.point.x + 12, e.point.y + 12]], {
        layers: ["pm-rally", "pm-start", "pm-route", "pm-pin", "pm-road-point", "pm-road-line", "pm-gauge", "pm-warning-fill"] });
      say("tap", { longitude: e.lngLat.lng, latitude: e.lngLat.lat, longPress,
                   x: e.point.x, y: e.point.y,  // where in the page: the Mac's details point there (part 3)
                   features: near.slice(0, 5).map((f) => ({ layer: f.layer.id, id: f.id ?? null, ...f.properties,
                     // a point's own place, for directions to it (a line's is the tap)
                     at: f.geometry?.type === "Point" ? f.geometry.coordinates : null })) });
    };
    // A finger held still half a second is a long press (Task 11.2; F23: on the phone a long press drops a pin, and a
    // tap opens a spot only on something); the click that follows it is not a tap too.
    let held = null, pressed = false;
    const letGo = () => { if (held) { clearTimeout(held.timer); held = null; } };
    map.on("touchstart", (e) => {
      letGo();
      pressed = false;  // a hold that ended in a drag sends no click: the next tap is a tap (the phase 11 review)
      if (e.originalEvent.touches.length !== 1) return;
      held = { x: e.point.x, y: e.point.y, timer: setTimeout(() => { held = null; pressed = true; tap(e, true); }, 500) };
    });
    map.on("touchmove", (e) => { if (held && Math.hypot(e.point.x - held.x, e.point.y - held.y) > 10) letGo(); });
    map.on("touchend", letGo);
    map.on("touchcancel", letGo);
    map.on("movestart", letGo);
    // The iPad's trackpad: a click held as long is a long press too (street map fixes plan, task 5.1). Pointer events,
    // so a finger's own mouse events can't reset the touch hold above; not on the Mac (no touch), which right-clicks.
    if (navigator.maxTouchPoints > 0) {
      const canvas = map.getCanvasContainer();
      const at = (ev) => {
        const r = canvas.getBoundingClientRect();
        const point = { x: ev.clientX - r.left, y: ev.clientY - r.top };
        return { point, lngLat: map.unproject([point.x, point.y]) };
      };
      canvas.addEventListener("pointerdown", (ev) => {
        pressed = false;  // first: a hold that ended in a drag never eats the next two-finger click
        if (ev.pointerType !== "mouse" || ev.button !== 0) return;
        letGo();
        const e = at(ev);
        held = { x: e.point.x, y: e.point.y, timer: setTimeout(() => { held = null; pressed = true; tap(e, true); }, 500) };
      });
      canvas.addEventListener("pointermove", (ev) => {
        if (ev.pointerType !== "mouse" || !held) return;
        const e = at(ev);
        if (Math.hypot(e.point.x - held.x, e.point.y - held.y) > 10) letGo();
      });
      canvas.addEventListener("pointerup", (ev) => { if (ev.pointerType === "mouse") letGo(); });
    }
    // The Mac's right-click (or a two-finger click): the spot's details with Add rally point here (task 5.1)
    map.on("contextmenu", (e) => {
      e.originalEvent.preventDefault();
      // MapLibre raises this itself half a second into a finger's hold: the hold above already sent it (the W9 review)
      if (held || pressed) return;
      letGo();
      tap(e, true);
    });
    map.on("click", (e) => {
      if (pressed) { pressed = false; return; }
      tap(e, false);
    });
    setInterval(() => say("health", { loaded: map.loaded(), tiles: map.areTilesLoaded() }), 5000);
  },
  setDark(night) {
    if (!map || night === dark) return;
    dark = night;
    map.setStyle(withOverlays(styles[dark ? "dark" : "light"]));
    map.once("styledata", () => { map.getSource("position")?.setData(positionData()); });
  },
  setRed(on) {
    if (!map || on === red) return;
    red = on;
    map.setStyle(withOverlays(styles[dark ? "dark" : "light"]));
    map.once("styledata", () => { map.getSource("position")?.setData(positionData()); });
  },
  setData(name, json) { if (SOURCES.includes(name) && name !== "position") put(name, json); },
  setPosition(lat, lon, accuracy, heading, stale = false) {
    position = { lat, lon, accuracy, heading: heading == null || heading < 0 ? NaN : heading, stale: stale === true };
    map?.getSource("position")?.setData(positionData());
  },
  clearPosition() { position = null; map?.getSource("position")?.setData(EMPTY); },
  flyTo(longitude, latitude, zoom) { map?.flyTo({ center: [longitude, latitude], zoom: zoom ?? Math.max(map.getZoom(), 15) }); },
  // Follow me (task 1.2): the map's middle eased to each fix at the zoom the person chose; skipped while it is still
  // moving (Find me's flight, a pinch), so it never fights a finger or cuts a flight short.
  follow(longitude, latitude) {
    if (!map || map.isMoving()) return;
    map.easeTo({ center: [longitude, latitude], duration: 600 });
  },
  fit(west, south, east, north) { map?.fitBounds([[west, south], [east, north]], { padding: 48, maxZoom: 16 }); },
  resetNorth() { map?.easeTo({ bearing: 0, pitch: 0 }); },
  // The printed household map: the area shown at once, north up, then the picture once every tile is drawn.
  // Always in the light style, whatever the screen shows: paper is white; the marks in their paper look (F29).
  // With no area (the phone's Save as PDF, street map fixes plan, task 4.2): the view on screen, north up, and the
  // view put back as it was after.
  async snapshot(west, south, east, north) {
    const here = west == null;
    const was = { center: map.getCenter(), zoom: map.getZoom(), bearing: map.getBearing(), pitch: map.getPitch() };
    map.setStyle(withOverlays(styles.light, true));
    if (here) map.jumpTo({ bearing: 0, pitch: 0 });
    else map.fitBounds([[west, south], [east, north]], { padding: 40, maxZoom: 16, bearing: 0, pitch: 0, duration: 0 });
    await new Promise((done) => map.once("idle", done));
    const picture = map.getCanvas().toDataURL("image/png");
    const b = map.getBounds();  // the whole picture's area, padding included: the grid and scale are drawn to it
    map.setStyle(withOverlays(styles[dark ? "dark" : "light"]));  // the screen's look back
    if (here) map.jumpTo(was);
    map.once("styledata", () => { map.getSource("position")?.setData(positionData()); });
    return JSON.stringify({ png: picture, bounds: [b.getWest(), b.getSouth(), b.getEast(), b.getNorth()] });
  },
};
say("page");
