/* The game kit: what every game of ours shares (docs/plans/2026-11-17-games-refresh.md, section 13 part C).

   - The look: light, dark or the red night screen (the app marks a red-night page with data-pm-red on <html>).
   - The room a game has: the part of the page a person can see and press. Edge to edge and the safe-area figures
     are used ONLY when the app says the page is in full screen (data-pm-full on <html>); outside it the reader lays
     an edge-to-edge page under its own bars and the lowest strip takes no presses (FINDINGS F-127).
   - Saves that never throw, a wait that stops while the page is hidden, Reduce Motion, words for VoiceOver, and
     effects that stay silent until someone turns them on. No music. Nothing here reaches outside the page but the
     app's own store for a game's save, and the household's players the app offers (read only, but for the device's
     usual player).

   Options for checks, from the address (?a=1&b=2 or #a=1&b=2) or a page that sets window.PM_OPTS itself:
   look=light|dark|red   fast=1 (no motion, no waiting) */
var PMKit = (function () {
  'use strict';
  var root = document.documentElement, heard = [], probe = null, sayBox = null, again = 0;
  var ASK = new URLSearchParams(window.PM_OPTS || location.search.slice(1) || location.hash.slice(1));
  var calmAsk = matchMedia('(prefers-reduced-motion: reduce)'), darkAsk = matchMedia('(prefers-color-scheme: dark)');

  function look() { return ASK.get('look') || (root.hasAttribute('data-pm-red') ? 'red' : darkAsk.matches ? 'dark' : 'light'); }
  function full() { return root.hasAttribute('data-pm-full'); }
  function calm() { return calmAsk.matches || ASK.has('fast'); }

  // The viewport line: edge to edge only in the app's full screen.
  function fit() {
    var meta = document.querySelector('meta[name=viewport]');
    var want = 'width=device-width, initial-scale=1, user-scalable=no' + (full() ? ', viewport-fit=cover' : '');
    if (meta && meta.getAttribute('content') !== want) meta.setAttribute('content', want);
    root.setAttribute('data-look', look());
    root.toggleAttribute('data-calm', calm());
  }

  // Where the game may draw, in page points: {left, top, w, h, dpr, full, safe: {t, r, b, l}}.
  function view() {
    var vv = window.visualViewport, safe = { t: 0, r: 0, b: 0, l: 0 };
    if (full()) {
      var p = getComputedStyle(probe);
      safe = { t: parseFloat(p.paddingTop) || 0, r: parseFloat(p.paddingRight) || 0, b: parseFloat(p.paddingBottom) || 0, l: parseFloat(p.paddingLeft) || 0 };
    }
    return {
      left: vv ? vv.offsetLeft : 0, top: vv ? vv.offsetTop : 0,
      w: Math.max(Math.round(vv ? vv.width : window.innerWidth), 1), h: Math.max(Math.round(vv ? vv.height : window.innerHeight), 1),
      dpr: Math.min(window.devicePixelRatio || 1, 3), full: full(), safe: safe
    };
  }

  // Tell a game when its look, its room or the page's being seen has changed; the game reads them again.
  // The safe-area figures can arrive a moment after the size does (seen in the simulators, 2026-11-17: a hand laid
  // out with the old figures sat on the home bar), so the game is told again shortly after, and whenever they move.
  function on(fn) { heard.push(fn); }
  function tell() { fit(); heard.forEach(function (fn) { fn(); }); }
  function changed() { tell(); clearTimeout(again); again = setTimeout(tell, 300); }
  probe = document.createElement('div');                                     // as big as the safe-area figures: it changes when they do
  probe.style.cssText = 'position:fixed;left:0;top:0;visibility:hidden;pointer-events:none;padding:env(safe-area-inset-top) ' +
    'env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)';
  (document.body || root).appendChild(probe);
  if (window.ResizeObserver) new ResizeObserver(changed).observe(probe);
  window.addEventListener('resize', changed);
  if (window.visualViewport) { visualViewport.addEventListener('resize', changed); visualViewport.addEventListener('scroll', changed); }
  new MutationObserver(changed).observe(root, { attributes: true, attributeFilter: ['data-pm-red', 'data-pm-full'] });
  darkAsk.addEventListener('change', changed); calmAsk.addEventListener('change', changed);
  document.addEventListener('visibilitychange', changed);
  // A focus ring is for someone using keys: after a press it would only be a stray outline (kit.css reads data-keys).
  window.addEventListener('keydown', function () { root.setAttribute('data-keys', ''); }, true);
  window.addEventListener('pointerdown', function () { root.removeAttribute('data-keys'); }, true);

  // Saves: a page may be loaded twice in one launch and reloaded at any moment, so a game saves after every move.
  // A game's own save (the key pm-<its folder>, as pm-cardtable) is kept by the app when the app offers it: the app
  // marks the page data-pm-games="<key>" before any script runs, with its copy of the save in data-pm-save and that
  // copy's count in data-pm-n (none: it holds none yet), and takes each new save as a message (players plan, stages 1
  // and 1b; GameBridge in the app). Every save also goes to the page's own storage, so an older app or games file, or
  // a launch when the app can't offer, finds the latest game there.
  // The counts: each save carries one more than the last this page knew, beside the game's own text (the page's
  // storage holds it as "<key>:n", {n, h}, h a fingerprint of the text it counts), and the higher count wins wherever
  // it is: the app keeps a save only over a lower count, and a page starts from whichever copy, the app's or the
  // page's, counts higher. A copy with no count is count 0; a copy changed since its count was written (an older kit
  // saved it) counts one more. A page that finds another page of the same game ahead of it reloads, to start from
  // the newest, rather than overwrite it.
  var B = null, counts = {}, OLDER = 'an older save than the one kept';
  function mark(text) {
    for (var i = 0, h = 5381; i < text.length; i++) h = ((h << 5) + h + text.charCodeAt(i)) | 0;
    return (h >>> 0).toString(36) + '.' + text.length;
  }
  function inPage(key) {                       // the page's copy and its count (-1: none); stale: its count not written
    try {
      var text = localStorage.getItem(key), was = JSON.parse(localStorage.getItem(key + ':n') || 'null');
      if (text === null) return { n: -1, text: null };
      if (!was || typeof was.n !== 'number') return { n: 0, text: text, stale: true };
      var same = was.h === mark(text);
      return { n: same ? was.n : was.n + 1, text: text, stale: !same };
    } catch (e) { return { n: -1, text: null }; }
  }
  function toPage(key, text, n) {
    try { localStorage.setItem(key, text); localStorage.setItem(key + ':n', JSON.stringify({ n: n, h: mark(text) })); } catch (e) {}
  }
  // A copy this page plays from gets the count it was read at written beside it, so the next change an older kit
  // makes counts one past that, not the same count again.
  function settle(key, p) { if (p.stale) toPage(key, p.text, p.n); }
  function behind() { location.reload(); }
  (function () {
    var key = root.getAttribute('data-pm-games');
    if (!key) return;
    var held = root.getAttribute('data-pm-save'), heldN = held === null ? -1 : parseInt(root.getAttribute('data-pm-n'), 10) || 0;
    root.removeAttribute('data-pm-games'); root.removeAttribute('data-pm-save'); root.removeAttribute('data-pm-n');
    var page = inPage(key);
    B = { key: key, text: held, waiting: {}, n: 0 };
    document.addEventListener('pm-game-answer', function (event) {
      var said; try { said = JSON.parse(event.detail); } catch (e) { return; }
      var done = said && B.waiting[said.id];
      if (done) { delete B.waiting[said.id]; done(said); }
    });
    if (page.n > heldN) {                                        // the page's copy is newer: the app takes it
      B.text = page.text; counts[key] = { n: page.n, text: page.text }; settle(key, page); keep(page.text, page.n);
    } else {
      counts[key] = { n: Math.max(heldN, 0), text: held };
      // the page's copy catches up, for an older kit
      if (held !== null && (heldN > page.n || page.stale || page.text !== held)) toPage(key, held, heldN);
    }
  })();
  function ask(message, wait) {
    return new Promise(function (done) {
      var id = ++B.n;
      B.waiting[id] = done; message.id = id;
      document.dispatchEvent(new CustomEvent('pm-game-ask', { detail: JSON.stringify(message) }));
      setTimeout(function () { if (B.waiting[id]) { delete B.waiting[id]; done({ ok: false, why: 'no answer' }); } }, wait || 10000);
    });
  }
  // Told older, another page of this game is ahead: start again from the newest. Any other no, or no answer, the
  // page's own counted copy already holds the save and wins at the next start.
  function keep(text, n) {
    ask({ v: 1, ask: 'keep', key: B.key, save: text, n: n }).then(function (said) { if (!said.ok && said.why === OLDER) behind(); });
  }
  function load(key) {
    try {
      if (B && key === B.key) return JSON.parse(B.text || 'null');
      var p = inPage(key);                                       // the count this page plays from, noted as it loads
      if (!counts[key]) { counts[key] = { n: Math.max(p.n, 0), text: p.text }; settle(key, p); }
      return JSON.parse(p.text || 'null');
    } catch (e) { return null; }
  }
  function save(key, value) {
    try {
      var text = JSON.stringify(value), c = counts[key];
      if (!c) { var p = inPage(key); c = counts[key] = { n: Math.max(p.n, 0), text: p.text }; settle(key, p); }
      if (text === c.text) return true;                          // nothing new: no count spent
      var n = c.n + 1, now = inPage(key);
      if (now.n >= n) {                                          // another page of this game saved as far or further
        if (now.text !== text) { behind(); return true; }
        c.n = now.n; c.text = text; if (B && key === B.key) B.text = text; return true;
      }
      toPage(key, text, n);
      c.n = n; c.text = text;
      if (B && key === B.key) { B.text = text; keep(text, n); }
      return true;
    } catch (e) { return false; }
  }

  // Players (players plan, stage 2): the household's players from the app, those not retired, as [{id, name, color}],
  // with this device's usual player's number (or null). Null when there are none to offer: no bridge (an older app,
  // the test page in a browser), an app that doesn't know the ask, no answer within 3 seconds, or an empty list; a
  // game then asks for a typed name as before. A nickname is never written to the page's storage, which every page of
  // the games file reads: a game keeps only the chosen player's number there, and asks for the names each time.
  function players() {
    if (!B) return Promise.resolve(null);
    return ask({ v: 1, ask: 'players', key: B.key }, 3000).then(function (said) {
      var list = said.ok && Array.isArray(said.players) ? said.players.filter(function (p) {
        return p && typeof p.id === 'number' && typeof p.name === 'string' && p.name && typeof p.color === 'string';
      }) : [];
      return list.length ? { list: list, usual: typeof said.usual === 'number' ? said.usual : null } : null;
    });
  }
  // This device's usual player from now on (a game's first pick on the device). Nothing without the bridge.
  function usual(id) { if (B) ask({ v: 1, ask: 'usual', key: B.key, player: id }); }

  // A wait that doesn't end while the page is hidden, so a game stands still when the app leaves the screen.
  function sleep(ms) {
    return new Promise(function (done) {
      setTimeout(function wake() {
        if (!document.hidden) return done();
        document.addEventListener('visibilitychange', function seen() {
          if (document.hidden) return;
          document.removeEventListener('visibilitychange', seen); done();
        });
      }, ASK.has('fast') ? 0 : ms);
    });
  }

  // Words for VoiceOver: one polite live line, off the screen.
  function say(text) {
    if (!sayBox) {
      sayBox = document.createElement('div');
      sayBox.className = 'pm-hide'; sayBox.setAttribute('role', 'status'); sayBox.setAttribute('aria-live', 'polite');
      document.body.appendChild(sayBox);
    }
    sayBox.textContent = text;
  }

  // Effects: made here from plain tones and hiss, nothing loaded. Silent until sound(true), which a tap must call.
  var audio = null, soundOn = false, hiss = null;
  function sound(turnOn) {
    soundOn = !!turnOn;
    if (!soundOn) return;
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!audio && AC) audio = new AC();
    if (audio && audio.state === 'suspended') audio.resume();
  }
  function tone(freq, at, long, loud) {
    var o = audio.createOscillator(), g = audio.createGain(), t = audio.currentTime + at;
    o.frequency.value = freq; g.gain.setValueAtTime(loud, t); g.gain.exponentialRampToValueAtTime(0.0001, t + long);
    o.connect(g); g.connect(audio.destination); o.start(t); o.stop(t + long);
  }
  function rustle(long, pitch, loud) {
    if (!hiss) {
      hiss = audio.createBuffer(1, audio.sampleRate / 2, audio.sampleRate);
      var d = hiss.getChannelData(0); for (var i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    }
    var s = audio.createBufferSource(), f = audio.createBiquadFilter(), g = audio.createGain(), t = audio.currentTime;
    s.buffer = hiss; f.type = 'bandpass'; f.frequency.value = pitch; f.Q.value = 0.8;
    g.gain.setValueAtTime(loud, t); g.gain.exponentialRampToValueAtTime(0.0001, t + long);
    s.connect(f); f.connect(g); g.connect(audio.destination); s.start(t); s.stop(t + long);
  }
  function play(kind) {
    if (!soundOn || !audio || document.hidden) return;
    if (kind === 'card') rustle(0.07, 2600, 0.5);
    else if (kind === 'slide') rustle(0.22, 1400, 0.25);
    else if (kind === 'thud') tone(110, 0, 0.22, 0.5);
    else if (kind === 'chime') { tone(660, 0, 0.5, 0.2); tone(880, 0.16, 0.7, 0.2); }
  }

  fit();
  return { ASK: ASK, look: look, full: full, calm: calm, view: view, on: on, load: load, save: save, sleep: sleep,
    say: say, sound: sound, play: play, players: players, usual: usual };
})();
