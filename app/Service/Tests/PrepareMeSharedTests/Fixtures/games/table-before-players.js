/* The card table: one table for many card games (owner, 2026-11-17; docs/plans/2026-11-17-games-refresh.md,
   section 15). This is everything the games share: the picker, the player's name, the strength of the computer
   players, the two looks (lit.js, and flat.js as the low-power one), the menu, saves, records, the cards a person
   presses, and the words for VoiceOver. A game (hearts-play.js) adds itself with Table.add and plays through `T`.

   Presses: every card in the person's hand has a real button laid over it, so a tap, a click, the keyboard
   (Tab or the arrow keys, then Return) and VoiceOver all use the same path.

   Saved under one permanent key, after every card: {name, strength, table, sound, game, open, cast: {game: the three
   opponents of the game in hand}, saves: {game: its
   own}, records: {game: {strength: {played, won, streak, best}}}}. Nothing leaves the device.

   Options for checks (kit.js says how they are given): game=hearts (straight in, no picker)  name=Ava  seed=7
   strength=easy|medium|hard  table=lit|flat  auto=1 (plays the person's cards too)  fps=1 (the lit look counts its
   pictures a second while things move, for a device check)  players=2|3|4 (a game that takes two to four)
   unreleased=1 (shows the games that are not on RELEASED below: the test page's option)  goal=100 (the score
   that ends a game which lets the person choose it) */
var Table = (function () {
  'use strict';
  var K = PMKit, ASK = K.ASK, KEY = 'pm-cardtable', AUTO = ASK.has('auto');
  var $ = function (id) { return document.getElementById(id); };
  var data = K.load(KEY) || {}, games = {}, order = [], R = null, cards = [], gen = 0, pick = null;
  var handIds = [], btns = {}, last = { tents: [null, null, null, null], turn: -1, words: ['', ''] }, menuOpen = false, waiting = [], at = { key: '', lesson: false };
  var RANKS = ['2', '3', '4', '5', '6', '7', '8', '9', '10', 'jack', 'queen', 'king', 'ace'], SUITS = ['clubs', 'diamonds', 'spades', 'hearts'];
  // The computer opponents: six made-up nicknames (the owner, 2026-11-18: not Fox, Owl and Stag, which are cards).
  // Three are picked at random for each new game and stay with it until it ends.
  // Each is five letters or fewer, so it fits a name card and the flat table's score strip on a phone.
  var CAST = ['Briar', 'Ember', 'Flint', 'Moss', 'Pip', 'Sable'];
  data.saves = data.saves || {}; data.records = data.records || {}; data.count = data.count || {}; data.goal = data.goal || {}; data.cast = data.cast || {};
  // The card table's own release list (docs/games.md, "The card table's gate"). The table is released, so its files
  // ship with the next games file; a game that is not on this list does not exist for the page: no button on the
  // opening card, no way in from a save or from game= in the address. A key joins it only on the owner's word naming
  // the game. unreleased=1 in the address shows the others, for the test page in a browser.
  var RELEASED = ['hearts'];

  function store() { K.save(KEY, data); }
  function cardName(card) { var G = games[at.key]; return G && G.cardName ? G.cardName(card) : RANKS[card % 13] + ' of ' + SUITS[(card / 13) | 0]; }   // a game with a deck of its own names its cards
  function strength() { return ASK.get('strength') || data.strength || 'medium'; }
  function h(tag, props, kids) {
    var e = document.createElement(tag), k;
    for (k in props) { if (k === 'text') e.textContent = props[k]; else if (k === 'on') e.addEventListener('click', props[k]); else e.setAttribute(k, props[k]); }
    (kids || []).forEach(function (c) { if (c) e.appendChild(c); });
    return e;
  }

  // ---------------------------------------------------------------- the two looks
  function art(name) { return 'assets/' + name + '.jpg'; }
  function use(want) {
    var v = K.view(), look = K.look();
    if (R) R.stop();
    R = null;
    if (want !== 'flat' && Lit && Lit.start({ canvas: $('lit'), view: v, look: look, art: art, calm: K.calm, meter: ASK.has('fps') ? $('fps') : null,
      fail: function () { if (R === Lit) use('flat'); } })) R = Lit;                                    // a picture that won't load, or the drawing lost: the flat table takes over
    if (!R) { Flat.start({ box: $('flat'), view: v, look: look, calm: K.calm }); R = Flat; }
    $('lit').hidden = R !== Lit; $('flat').hidden = R !== Flat;
    R.cards(cards);
    last.tents.forEach(function (t, seat) { if (t) R.tent(seat, t[0], t[1], t[2]); });
    R.turn(last.turn); R.words(last.words[0], last.words[1]);
    placeUI();
  }
  function wanted() { return ASK.get('table') || data.table || 'lit'; }

  // ---------------------------------------------------------------- the person's cards: a button over each
  function setHand(ids) {
    var box = $('hand'), at = Array.prototype.indexOf.call(box.children, document.activeElement);
    handIds = ids.slice(); box.textContent = ''; btns = {};
    ids.forEach(function (id) {
      var b = h('button', { type: 'button', 'class': 'hc' });
      b.addEventListener('click', function () { if (pick) pick.tap(id); });
      b.addEventListener('pointerenter', function (e) { if (e.pointerType === 'mouse') hover(id); });
      b.addEventListener('pointerleave', function () { hover(-1); });
      b.addEventListener('focus', function () { hover(id); });
      b.addEventListener('blur', function () { hover(-1); });
      btns[id] = b; box.appendChild(b);
    });
    relabel(); placeUI();
    if (at >= 0 && box.children.length) box.children[Math.min(at, box.children.length - 1)].focus();
  }
  function relabel() {
    handIds.forEach(function (id) {
      var note = !pick ? '' : pick.picked.indexOf(id) >= 0 ? ', picked' : pick.legal.indexOf(id) < 0 ? ', can’t be played now' : id === pick.hint ? ', suggested' : '';
      btns[id].setAttribute('aria-label', cardName(id) + note);
    });
  }
  function hover(id) {
    handIds.forEach(function (c) {
      var k = cards[c].home, on = !!pick && c === id && pick.legal.indexOf(c) >= 0;
      if (k.kind === 'hand' && !!k.hover !== on) { k.hover = on; R.move(cards[c], { dur: 110 }); }
    });
  }
  $('hand').addEventListener('keydown', function (e) {
    if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
    var kids = this.children, at = Array.prototype.indexOf.call(kids, document.activeElement), n = kids.length;
    if (n) kids[(at < 0 ? 0 : at + (e.key === 'ArrowRight' ? 1 : n - 1)) % n].focus();
    e.preventDefault();
  });
  // For a check on a device or in a browser: points all over the cards of the hand, and what a press there reaches.
  // The card that shows at a point is the last one in the hand that covers it. Returns how many points were tried,
  // how many reach another card, and how many reach no card (points off the screen, or under the Draw button, don't count).
  function misses() {
    var v = K.view(), quads = R.handQuads(handIds), tried = 0, other = 0, none = 0;
    function local(q, x, y) { var dx = x - q.x, dy = y - q.y, c = Math.cos(q.r), s = Math.sin(q.r); return [(dx * c + dy * s) / q.w, (dy * c - dx * s) / q.h]; }
    quads.forEach(function (q) {
      for (var i = 0; i < 8; i++) for (var j = 0; j < 10; j++) {
        var u = (i + 0.5) / 8 * q.w, d = (j + 0.5) / 10 * q.h, x = q.x + u * Math.cos(q.r) - d * Math.sin(q.r), y = q.y + u * Math.sin(q.r) + d * Math.cos(q.r), top = q.id;
        if (x < v.left || y < v.top || x >= v.left + v.w || y >= v.top + v.h) continue;
        quads.forEach(function (p) { var at = local(p, x, y); if (at[0] >= 0 && at[0] <= 1 && at[1] >= 0 && at[1] <= 1 && handIds.indexOf(p.id) > handIds.indexOf(top)) top = p.id; });
        if (top !== q.id) continue;                                          // another card lies over this point
        var e = document.elementFromPoint(x, y);
        if (e === $('go')) continue;
        tried++;
        if (e !== btns[q.id]) { if (e && e.classList.contains('hc')) other++; else none++; }
      }
    });
    return { tried: tried, other: other, none: none };
  }
  function placeUI() {
    if (!R) return;
    var v = K.view(), top = v.top + v.h;
    // Each button is its whole card, lying as the card lies and stacked as the cards are (a later card is over an
    // earlier one), so a press anywhere a card shows reaches that card. Until 2026-11-18 a button was only an upright
    // strip at the card's left edge: about a press in five on a card's face reached its neighbor or nothing (the
    // owner on an iPhone: "some difficulty selecting cards"). Table.misses() measures it.
    R.handQuads(handIds).forEach(function (q) {
      btns[q.id].style.cssText = 'left:' + q.x + 'px;top:' + q.y + 'px;width:' + q.w + 'px;height:' + q.h + 'px;transform:rotate(' + q.r + 'rad)';
      top = Math.min(top, q.y, q.y + q.w * Math.sin(q.r));
    });
    // above the hand, right of the middle (the middle is the person's name card and the turn marker), or at the side
    // where the room is short (a phone on its side) and all of the middle is the table
    $('go').style.top = (top - 42) + 'px'; $('go').style.left = (v.h < 480 ? v.left + v.w - v.safe.r - 70 : v.w < 500 ? v.left + v.w - v.safe.r - 56 : v.left + v.w * 0.72) + 'px';   // a phone held upright: at the edge, clear of the felt's words
    var pr = R.pileRect();                                                  // the draw pile takes a press where a game has one
    $('pile').style.cssText = 'left:' + pr.x + 'px;top:' + pr.y + 'px;width:' + pr.w + 'px;height:' + pr.h + 'px';
    $('menu-btn').style.top = (v.top + v.safe.t + 8) + 'px'; $('menu-btn').style.left = (v.left + v.w - v.safe.r - 10) + 'px';
    $('scene').style.cssText = 'left:' + (v.left + v.w * 0.2) + 'px;top:' + (v.top + v.h * 0.25) + 'px;width:' + (v.w * 0.6) + 'px;height:' + (v.h * 0.3) + 'px';
  }

  // The person chooses: one card to play (the cards that may be played lift, the rest sink), or `count` cards to
  // give away (each tapped card lifts; the go button sends them). o: {legal, count, go, why(card), auto(), start: cards
  // picked to begin with, hint: one card stood a little higher as the suggested one, side: [words, value] a button
  // beside the one-card choice that answers with `value` (Draw, Keep), pile: the draw pile answers with it too}.
  function choose(o) {
    var g = gen;
    return new Promise(function (resolve) {
      var many = (o.count || 1) > 1, go = $('go'), pile = $('pile');
      function mark() {
        handIds.forEach(function (id) {
          var k = cards[id].home, lift = pick ? (many ? pick.picked.indexOf(id) >= 0 : pick.legal.indexOf(id) >= 0) : false;
          var sunk = !!pick && !many && !lift, hint = !!pick && id === o.hint;
          if (k.kind === 'hand' && (!!k.lift !== lift || !!k.sunk !== sunk || !!k.hint !== hint || k.hover)) { k.lift = lift; k.sunk = sunk; k.hint = hint; k.hover = false; R.move(cards[id], { dur: 180 }); }
        });
        relabel(); placeUI();
        if (many && pick) go.disabled = pick.picked.length !== o.count;
      }
      function finish(value) { pick = null; go.hidden = true; go.onclick = null; pile.hidden = true; pile.onclick = null; mark(); resolve(value); }
      pick = { legal: o.legal, picked: (o.start || []).slice(), hint: o.hint, tap: function (id) {
        if (g !== gen) return;
        if (o.legal.indexOf(id) < 0) { say(last.words[0], o.why ? o.why(id) : ''); return; }
        if (!many) return finish(id);
        var at = pick.picked.indexOf(id);
        if (at >= 0) pick.picked.splice(at, 1); else if (pick.picked.length < o.count) pick.picked.push(id);
        mark();
      } };
      if (many) { go.textContent = o.go; go.hidden = false; go.onclick = function () { if (pick && pick.picked.length === o.count) finish(pick.picked.slice()); }; }
      else if (o.side) {
        go.textContent = o.side[0]; go.disabled = false; go.hidden = false; go.onclick = function () { if (pick && g === gen) finish(o.side[1]); };
        if (o.pile) { pile.hidden = false; pile.onclick = go.onclick; }
      }
      mark();
      if (AUTO) sleep(300).then(function () { if (pick && g === gen) finish(o.auto()); });
    });
  }

  // ---------------------------------------------------------------- words: on the table, and said for VoiceOver
  // `more` is only said, never shown: what a person who can't see the table needs with these words.
  function say(text, small, more) { last.words = [text, small || '']; R.words(text, small || ''); K.say([text, small, more].filter(Boolean).join('. ')); }
  function tents(names, totals, hands) {
    // a seat with no name is empty: it shows no name card. hands[seat]: a number is shown as "+3", words as they are
    for (var seat = 0; seat < 4; seat++) { last.tents[seat] = [names[seat], totals[seat], hands[seat]]; R.tent(seat, names[seat], totals[seat], hands[seat]); }
  }
  function turn(seat) { last.turn = seat; R.turn(seat); }

  // ---------------------------------------------------------------- paper cards over the table
  function paper(kids, label) {
    var p = $('paper'); p.textContent = ''; p.setAttribute('aria-label', label);
    kids.forEach(function (c) { if (c) p.appendChild(c); });
    $('veil').hidden = false; $('hand').inert = true; $('menu-btn').inert = true; $('go').inert = true; $('pile').inert = true;
    var first = p.querySelector('button.pm-first') || p.querySelector('button');
    if (first) first.focus();
  }
  function fold() {                                                         // the paper card goes; the keyboard and VoiceOver go back to the hand
    cheerNo++; $('cheer').hidden = true;
    $('veil').hidden = true; $('hand').inert = false; $('menu-btn').inert = false; $('go').inert = false; $('pile').inert = false; menuOpen = false;
    waiting.splice(0).forEach(function (go) { go(); });
    var back = $('hand').firstElementChild || $('menu-btn');
    if (!back.hidden) back.focus();
  }
  // A game's waits also wait for the paper card (the menu) to be put away, so nothing is played behind it.
  function sleep(ms) { return K.sleep(ms).then(function () { return $('veil').hidden ? null : new Promise(function (go) { waiting.push(go); }); }); }
  function mark() { return $('mark').content.cloneNode(true).firstElementChild; }
  function pickRow(choices, now, onPick, label) {
    var row = h('div', { 'class': 'pm-pick', role: 'group', 'aria-label': label });
    choices.forEach(function (c) {
      row.appendChild(h('button', { type: 'button', text: c[1], 'aria-pressed': String(c[0] === now), on: function () {
        Array.prototype.forEach.call(row.children, function (b) { b.setAttribute('aria-pressed', String(b === this)); }, this);
        onPick(c[0]);
      } }));
    });
    return row;
  }

  // A paper card with buttons; resolves with the pressed button's value. o: {label, kids, buttons: [[text, value, quiet,
  // a small picture to stand before the words]], auto: the value a self-playing check answers with, cheer: 'hand' or
  // 'game' for a festive pad, who: the seat it cheers, name: that player's name (a computer winner's medal shows its
  // first letter)}.
  function suitMark(suit) {                                                 // a suit's mark for a button, from the deck in use
    var c = h('canvas', { 'class': 'sm', width: '56', height: '56', 'aria-hidden': 'true' });
    CardFaces.suitMark(c.getContext('2d'), suit, 28, 28, 50, K.look() === 'red');
    return c;
  }
  function pad(o) {
    var g = gen;
    return new Promise(function (resolve) {
      paper((o.cheer ? [banner(o.cheer, o.who, o.name)] : []).concat(o.kids, o.buttons.map(function (b, i) {
        var btn = h('button', { type: 'button', 'class': 'pm-wide' + (b[2] ? ' pm-quiet' : '') + (i ? '' : ' pm-first'), text: b[0], on: function () { if (g !== gen) return; fold(); resolve(b[1]); } });
        if (b[3]) btn.insertBefore(b[3], btn.firstChild);
        return btn;
      })), o.label);
      if (o.cheer) fall(o.cheer, o.who);
      if (AUTO && o.auto) K.sleep(1200).then(function () { if (g === gen && !$('veil').hidden) { fold(); resolve(o.auto); } });
    });
  }

  // A festive score pad. Over its headline hangs a garland of the deck's suit marks, and at a game's end the winner's
  // medal; behind the paper card the same marks fall for a moment (more of them when the person won). With Reduce
  // Motion they lie still. Nothing is loaded and nothing here makes a sound.
  var cheerNo = 0;
  function banner(kind, who, name) {
    var big = kind === 'game', w = 280, ht = big ? 100 : 46, red = K.look() === 'red', gold = red ? '#a3251e' : CardFaces.GOLD;
    var c = h('canvas', { 'class': 'cheer-top', width: String(w * 2), height: String(ht * 2), 'aria-hidden': 'true' }), ctx = c.getContext('2d'), dip = big ? 38 : 24;
    ctx.scale(2, 2); ctx.strokeStyle = gold; ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.moveTo(8, 6); ctx.quadraticCurveTo(w / 2, 6 + dip, w - 8, 6); ctx.stroke();   // the string
    for (var i = 0; i < 9; i++) {
      if (big && i > 2 && i < 6) continue;                                   // the medal hangs in the middle
      var k = (i + 0.5) / 9;
      CardFaces.suitMark(ctx, i % 4, 8 + k * (w - 16), 6 + 2 * k * (1 - k) * dip + 14, 22, red);
    }
    if (big) {
      ctx.beginPath(); ctx.arc(w / 2, 58, 40, 0, 7); ctx.fillStyle = gold; ctx.fill();
      ctx.beginPath(); ctx.arc(w / 2, 58, 35, 0, 7); ctx.fillStyle = red ? '#170403' : '#f1e4c3'; ctx.fill();
      if (!who) CardFaces.portrait(ctx, w / 2, 58, 70, red);                // the person: the four-color compass point
      else {                                                                 // a computer opponent: its first letter
        ctx.font = '700 44px ui-serif, "New York", Georgia, serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        ctx.fillStyle = red ? '#ff4338' : '#2a2622'; ctx.fillText(String(name || '?').charAt(0), w / 2, 60);
      }
    }
    return c;
  }
  function fall(kind, who) {
    var sky = $('cheer'), no = ++cheerNo, red = K.look() === 'red', still = K.calm(), dpr = Math.min(window.devicePixelRatio || 1, 2), marks = [], bits = [], i;
    sky.hidden = false;
    var W = sky.clientWidth, H = sky.clientHeight, n = Math.round((kind === 'game' ? 80 : 34) * (who === 0 ? 1 : 0.45)), long = kind === 'game' ? 3600 : 1500;
    sky.width = Math.round(W * dpr); sky.height = Math.round(H * dpr);
    for (i = 0; i < 4; i++) { var m = document.createElement('canvas'); m.width = m.height = 64; CardFaces.suitMark(m.getContext('2d'), i, 32, 32, 56, red); marks.push(m); }
    for (i = 0; i < n; i++) bits.push({ x: Math.random() * W, y: Math.random() * H, at: Math.random() * long, v: 0.16 + Math.random() * 0.16, sway: 10 + Math.random() * 24, ph: Math.random() * 7,
      spin: (Math.random() - 0.5) * 0.005, size: 15 + Math.random() * 15, mark: marks[i % 4] });
    var ctx = sky.getContext('2d'), t0 = performance.now();
    function draw(now) {
      if (no !== cheerNo) return;
      var t = now - t0, live = false;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, W, H);
      bits.forEach(function (b) {
        var y = still ? b.y : -30 + (t - b.at) * b.v;
        if (y < -30 || y > H + 30) { live = live || y < -30; return; }
        live = true;
        ctx.save(); ctx.translate(b.x + (still ? 0 : Math.sin(b.ph + t * 0.003) * b.sway), y); ctx.rotate(b.ph + (still ? 0 : t * b.spin));
        ctx.drawImage(b.mark, -b.size / 2, -b.size / 2, b.size, b.size); ctx.restore();
      });
      if (still) return;                                                      // Reduce Motion: they lie where they fell
      if (live) requestAnimationFrame(draw); else sky.hidden = true;
    }
    requestAnimationFrame(draw);
  }

  function recordLine(key) {
    var r = (data.records[key] || {})[strength()];
    return r && r.played ? games[key].title + ', ' + strength() + ': won ' + r.won + ' of ' + r.played + (r.best > 1 ? ', best run ' + r.best : '') + '.' : '';
  }

  // The opening card: pick a game, type a name, set the computer players, carry on or deal.
  function picker() {
    gen++; pick = null; data.open = ''; at = { key: '', lesson: false }; store(); $('go').hidden = true; $('pile').hidden = true; $('menu-btn').hidden = true;
    var key = games[data.game] ? data.game : order[0], G = games[key], sv = data.saves[key];
    var name = h('input', { type: 'text', maxlength: '12', placeholder: 'Your name', 'aria-label': 'Your name', autocomplete: 'off' });
    name.value = data.name || '';
    function go(fresh) {
      data.name = name.value.trim() || 'You'; data.game = key;
      if (fresh) { delete data.saves[key]; delete data.cast[key]; }
      play(key);
    }
    paper([
      mark(), h('h1', { text: 'The Card Table' }),
      order.length > 1 ? pickRow(order.map(function (k) { return [k, games[k].title]; }), key, function (k) { data.game = k; picker(); }, 'Game') : h('h2', { text: G.title }),
      h('p', { text: G.blurb }),
      name,
      h('h2', { text: 'Computer players' }),
      G.seats ? pickRow(G.seats.map(function (n) { return [n, ['One', 'Two', 'Three'][n - 2]]; }), count(key), function (n) { data.count[key] = n; store(); }, 'How many computer players') : null,
      pickRow([['easy', 'Easy'], ['medium', 'Medium'], ['hard', 'Hard']], strength(), function (v) { data.strength = v; store(); }, 'How strong the computer players are'),
      G.goals ? h('h2', { text: 'Game ends at' }) : null,
      G.goals ? pickRow(G.goals.map(function (n) { return [n, String(n)]; }), goal(key), function (n) { data.goal[key] = n; store(); }, 'The score that ends the game') : null,
      sv ? h('button', { type: 'button', 'class': 'pm-wide pm-first', text: 'Continue', on: function () { go(false); } }) : null,
      sv ? h('p', { 'class': 'plain', text: G.summary(sv) }) : null,
      h('button', { type: 'button', 'class': 'pm-wide' + (sv ? ' pm-quiet' : ' pm-first'), text: sv ? 'New game' : 'Deal', on: function () { go(true); } }),
      G.lesson ? h('button', { type: 'button', 'class': 'pm-wide pm-quiet', text: 'Show me how', on: function () { data.name = name.value.trim() || 'You'; data.game = key; play(key, true); } }) : null,
      recordLine(key) ? h('p', { 'class': 'plain', text: recordLine(key) }) : null,
      data.records[key] ? h('button', { type: 'button', 'class': 'pm-wide pm-quiet', text: 'Record', on: function () { record(key, picker); } }) : null,
      K.full() ? null : h('p', { 'class': 'plain', text: 'A newer PrepareMe plays this in full screen.' })
    ], 'The Card Table');
  }

  function menu() {
    // `at` is the game on the table now, a lesson too (a lesson is never the saved `open` game, so a page loaded again
    // opens on the card; the menu went by `open` and did nothing in a lesson: owner, 2026-11-17).
    var G = games[at.key]; if (!G) return;
    var kept = at.lesson ? null : data.saves[at.key], seen = G.look && kept ? G.look(kept, seated(at.key), cardName) : null;
    var how = h('details', {}, [h('summary', { text: 'How to play' })].concat(G.how.map(function (t) { return h('p', { text: t }); }),
      G.rules ? [h('p', {}, [h('a', { href: G.rules, text: 'The full rules' })])] : []));
    paper([
      h('h1', { text: G.title }), how,
      h('h2', { text: 'Table' }),
      Lit ? pickRow([['lit', 'Lit'], ['flat', 'Flat']], R.name, function (v) { data.table = v; store(); use(v); }, 'Table') : null,
      h('p', { 'class': 'plain', text: Lit ? 'Flat draws less and saves battery.' : 'This copy has the flat table only.' }),
      h('h2', { text: 'Sound' }),
      pickRow([['off', 'Off'], ['on', 'On']], data.sound ? 'on' : 'off', function (v) { data.sound = v === 'on'; store(); K.sound(data.sound); K.play('card'); }, 'Sound'),
      h('button', { type: 'button', 'class': 'pm-wide pm-first', text: at.lesson ? 'Back to the lesson' : 'Back to the game', on: fold }),
      seen ? h('button', { type: 'button', 'class': 'pm-wide pm-quiet', text: 'Look back at the last hand', on: function () { look(seen).then(menu); } }) : null,
      data.records[at.key] ? h('button', { type: 'button', 'class': 'pm-wide pm-quiet', text: 'Record', on: function () { record(at.key, menu); } }) : null,
      at.lesson ? h('button', { type: 'button', 'class': 'pm-wide pm-quiet', text: 'Play a game', on: function () { play(at.key); } })
        : h('button', { type: 'button', 'class': 'pm-wide pm-quiet', text: 'New game', on: function () { delete data.saves[at.key]; play(at.key); } }),
      h('button', { type: 'button', 'class': 'pm-wide pm-quiet', text: 'Choose a game', on: picker })
    ], G.title + ' menu');
    menuOpen = true;
  }
  $('menu-btn').addEventListener('click', menu);
  window.addEventListener('keydown', function (e) { if (e.key === 'Escape' && menuOpen) fold(); });   // the menu only: a score pad waits for its own buttons

  // ---------------------------------------------------------------- playing a game
  // lesson: the game's guided first hand. Nothing of it is saved or counted, and a page loaded again opens on the card.
  function play(key, lesson) {
    var g = ++gen, G = games[key];
    pick = null; data.open = lesson ? '' : key; at = { key: key, lesson: !!lesson }; store(); fold(); $('go').hidden = true; $('pile').hidden = true; $('menu-btn').hidden = false;
    if (CardFaces.deck !== (G.deck || '')) { CardFaces.deck = G.deck || ''; CardFaces.kind = G.face || null; if (Lit) Lit.faces(); Flat.sheet(K.look() === 'red'); }   // the game's own deck
    setTimeout(function () { Flat.sheet(K.look() === 'red'); }, 3000);       // the look back's small cards, made ready ahead of the first pad
    var T = {
      names: seated(key, lesson), strength: strength(), seed: ASK.has('seed') ? +ASK.get('seed') : undefined, lesson: !!lesson,
      players: count(key), target: goal(key), suitMark: suitMark,
      alive: function () { return g === gen; },
      saved: function () { return lesson ? null : data.saves[key] || null; },
      keep: function (sv) { if (!lesson) { data.saves[key] = sv; store(); } },
      done: function (won, sv) {                                            // the game is over: count it once, drop its save
        var all = data.records[key] = data.records[key] || {}, r = all[sv.strength] = all[sv.strength] || { played: 0, won: 0, streak: 0, best: 0 };
        r.played++; if (won) { r.won++; r.streak++; r.best = Math.max(r.best, r.streak); } else r.streak = 0;
        if (G.tally) G.tally(r, won, sv);                                   // the game's own lines of the record
        delete data.saves[key]; delete data.cast[key]; store();          // the next game draws its own three
      },
      deck: function (seed) {                                               // 52 fresh cards, each lying a little askew in its own way
        cards = []; for (var id = 0; id < 52; id++) cards.push({ id: id, home: { kind: 'deck', i: id }, jit: Math.sin(id * 12.9898 + seed) * 0.6 });
        setHand([]); R.cards(cards); return cards;
      },
      rest: function (c) { R.rest(c); }, move: function (c, o) { return R.move(c, o); }, redraw: function () { R.redraw(); },
      hand: setHand, choose: choose, say: say, tell: K.say, tents: tents, turn: turn, sleep: sleep, pad: pad, sound: K.play,
      scene: function (text) { $('scene').textContent = text; }, name: cardName, h: h, picker: picker, again: function () { play(key); }, look: look
    };
    G.run(T);
  }

  // Who sits down: the person, then the game's three opponents (left, across, right). A new game picks three of the
  // cast at random and keeps them in the table's own save; a lesson, and a check that gives a seed, sit the first three.
  function seated(key, lesson) {
    var three = CAST.slice(0, 3);
    if (!lesson && !ASK.has('seed')) {
      three = data.cast[key];
      if (!three || three.length !== 3 || three.some(function (n) { return CAST.indexOf(n) < 0; })) {
        var pool = CAST.slice();
        three = [0, 1, 2].map(function () { return pool.splice((Math.random() * pool.length) | 0, 1)[0]; });
        data.cast[key] = three; store();
      }
    }
    return [data.name || 'You'].concat(three);
  }

  // How many sit down to a game that takes two to four (the person among them).
  function count(key) { var G = games[key], n = +ASK.get('players') || data.count[key] || 4; return G.seats && G.seats.indexOf(n) >= 0 ? n : 4; }

  // The score that ends a game which lets the person choose it (`goals`, and `goal` to start with).
  function goal(key) { var G = games[key], n = +ASK.get('goal') || data.goal[key] || G.goal; return G.goals && G.goals.indexOf(n) >= 0 ? n : G.goal; }

  // The record: for each strength, games played and won, the best run of wins, and the game's own lines.
  function record(key, back) {
    var G = games[key], all = data.records[key] || {}, cols = [['Played', 'played'], ['Won', 'won'], ['Best run', 'best']].concat(G.recordCols || []);
    var head = h('tr', {}, [h('th', { text: '' })].concat(cols.map(function (c) { return h('th', { scope: 'col', text: c[0] }); })));
    var rows = [['easy', 'Easy'], ['medium', 'Medium'], ['hard', 'Hard']].map(function (s) {
      var r = all[s[0]] || {};
      return h('tr', {}, [h('th', { scope: 'row', text: s[1] })].concat(cols.map(function (c) { return h('td', { text: r[c[1]] === undefined || r[c[1]] === null ? (r.played ? '–' : '') : String(r[c[1]]) }); })));
    });
    paper([h('h1', { text: 'Record' }), h('p', { text: G.title + ', on this device.' }), h('table', { 'class': 'pad' }, [h('thead', {}, [head]), h('tbody', {}, rows)]),
      G.recordNote ? h('p', { 'class': 'plain', text: G.recordNote }) : null,
      h('button', { type: 'button', 'class': 'pm-wide pm-first', text: 'Back', on: back })], 'Record');
  }

  // A small card: its corner (the rank and the suit), or the whole face when `whole`. Cut from the deck's one sheet.
  function mini(card, whole, on) {
    var w = whole ? 46 : 92, hgt = whole ? 64 : 129, col = card % 9, row = (card / 9) | 0;   // the sheet's cells at this size (table.css)
    var e = h('span', { 'class': 'mc' + (whole ? ' whole' : '') + (on ? ' on' : ''), role: 'img', 'aria-label': cardName(card) });
    e.style.backgroundPosition = (-(col * w) - (whole ? 0 : 2)) + 'px ' + (-(row * hgt) - (whole ? 0 : 2)) + 'px';
    return e;
  }

  // The look back at a finished hand: step through its tricks with every hand face up. o: {title, names (an empty
  // seat has none), what: a step's word when it isn't "trick", steps}, each step {title, says, hands: four lists as
  // they stood before the trick, trick: [{seat, card}], winner, taken: four, or notes: four lines to show in their
  // place}. Resolves when it is put away.
  function look(o) {
    var g = gen, at = 0;
    Flat.sheet(K.look() === 'red');
    return new Promise(function (resolve) {
      function leave() { window.removeEventListener('keydown', keys); $('paper').classList.remove('wide'); resolve(); }
      function keys(e) { if (e.key === 'ArrowRight' && at < o.steps.length - 1) { at++; show(); } else if (e.key === 'ArrowLeft' && at > 0) { at--; show(); } }
      function show() {
        if (g !== gen) return leave();
        var s = o.steps[at], played = {};
        s.trick.forEach(function (t) { played[t.card] = true; });
        var trick = h('div', { 'class': 'lb-trick' }, s.trick.map(function (t) {
          return h('div', { 'class': t.seat === s.winner ? 'won' : '' }, [mini(t.card, true), h('span', { text: t.label || o.names[t.seat] })]);
        }));
        var hands = h('div', { 'class': 'lb-hands' }, o.names.map(function (name, seat) {
          return name ? h('div', {}, [h('b', { text: name + ' ' }), h('i', { text: s.notes ? s.notes[seat] : s.taken[seat] + (s.taken[seat] === 1 ? ' point' : ' points') }),
            h('div', {}, s.hands[seat].map(function (c) { return mini(c, false, played[c]); }))]) : null;
        }));
        paper([h('h1', { text: o.title }), h('p', { text: s.title }), trick, h('p', { 'class': 'plain lb-says', text: s.says }), hands,
          h('div', { 'class': 'pm-pick' }, [
            h('button', { type: 'button', text: 'Back', 'aria-label': 'The ' + (o.what || 'trick') + ' before', on: function () { if (at > 0) { at--; show(); } } }),
            h('button', { type: 'button', 'class': 'pm-first', text: 'Next', 'aria-label': 'The next ' + (o.what || 'trick'), on: function () { if (at < o.steps.length - 1) { at++; show(); } } })]),
          h('button', { type: 'button', 'class': 'pm-wide pm-quiet', text: 'Done', on: function () { fold(); leave(); } })], o.title);
        $('paper').classList.add('wide');
        K.say(s.title + '. ' + s.says);
      }
      window.addEventListener('keydown', keys);
      show();
    });
  }

  function add(key, game) { if (RELEASED.indexOf(key) < 0 && !ASK.has('unreleased')) return; games[key] = game; order.push(key); }
  function start() {
    use(wanted());
    K.on(function () { R.relook(K.look()); R.resize(K.view()); placeUI(); if (!document.hidden) R.redraw(); });
    document.addEventListener('pointerdown', function () { if (data.sound) K.sound(true); }, { once: true });   // sound needs a tap first
    if (ASK.has('name')) data.name = ASK.get('name');
    var straight = ASK.get('game');
    if (straight && games[straight]) { if (ASK.has('seed')) delete data.saves[straight]; data.game = straight; return play(straight); }
    if (data.open && games[data.open] && data.saves[data.open]) return play(data.open);   // a reload mid-game: straight back to it
    picker();
  }
  return { add: add, start: start, misses: misses, games: function () { return order.slice(); } };
})();
