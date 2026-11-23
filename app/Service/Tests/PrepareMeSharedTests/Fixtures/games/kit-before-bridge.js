/* The game kit: what every game of ours shares (docs/plans/2026-11-17-games-refresh.md, section 13 part C).

   - The look: light, dark or the red night screen (the app marks a red-night page with data-pm-red on <html>).
   - The room a game has: the part of the page a person can see and press. Edge to edge and the safe-area figures
     are used ONLY when the app says the page is in full screen (data-pm-full on <html>); outside it the reader lays
     an edge-to-edge page under its own bars and the lowest strip takes no presses (FINDINGS F-127).
   - Saves that never throw, a wait that stops while the page is hidden, Reduce Motion, words for VoiceOver, and
     effects that stay silent until someone turns them on. No music. Nothing here reaches outside the page.

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
  function load(key) { try { return JSON.parse(localStorage.getItem(key) || 'null'); } catch (e) { return null; } }
  function save(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); return true; } catch (e) { return false; } }

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
    say: say, sound: sound, play: play };
})();
