// The PrepareMe app's live block (plan phase 5), run in the daily library's front page on the phone only. The app
// reads the conditions feeds itself and calls window.PrepareMeLive.apply(payload) with app/Service's LivePayload. Each
// call first puts the page back as the Mac wrote it, then lays the new block over it, so a later call never inherits
// what an earlier one hid or moved:
//
// - Every age line the Mac wrote with the phones' 8-hour floor goes back to its block's own limit
//   (data-own-stale-hours), so the Mac's copy is judged as the build plan's combination rule says.
// - With no block (payload.html empty: the library carries no settings the app can read), that is all: the Mac's
//   panels stay in their own places.
// - Otherwise the block (payload.html) is laid out. Each feed the phone couldn't read in the last 2 hours stands in it
//   as a slot (data-pm-mac), and the Mac's own block for that feed is moved into the slot, with the cross-check lines
//   that follow it; the rest of a panel's Mac blocks (FEMA's: any the block doesn't stand for) go to its data-pm-rest
//   slot, but never the laptop's own (LAPTOP: where the Mac is means nothing on a phone, which reads where it is
//   itself; owner 2026-10-15), which stay hidden with their panel. A phone reading older than the Mac's copy of the
//   same feed gives way to the Mac's block too (review C1: a stale "none" never hides a newer warning). A Mac block
//   leaves a marker where it came from, so it can go back; the page's script still reads every main reading
//   (data-core) and warning mark wherever they are.
// - Then each live panel goes where the Mac's page would put it (the Today redesign's phase 3, placeAll): a problem
//   card, worth a look, or a condition row (the phone's own, with its words, or the Mac's own row holding the panel
//   while a feed of it is the Mac's copy); the forecast into its fold. The Mac's own copies of the live panels (and a
//   cards box or Worth a look group left empty) are hidden, and so is a band headline from a feed the phone now shows;
//   the phone's own headlines join the band, with a mark for each kind of event the phone can start and the guide
//   button of each kind they start that the band lacks. The block's
//   group and note go in Sources and ages, at the page's end, where each feed the phone shows its own reading of
//   gives the newer time, the phone's or the Mac's (owner, 2026-10-28).
// - The answer box's Needs action line is written again: a live panel needs action when a phone block in it says so
//   (data-pm-needs), or when the Mac's line said so and a Mac block that needs action (data-needs) still stands in it
//   (any Mac block, on a page from before the Mac marked them); any other panel as the Mac's line said. The page's own script then runs again (a focus event), so ages, the banner and the mode follow.
// - The oldest-reading line and the 12-hour banner count each feed the phone read itself at the phone's time, never
//   the Mac's older copy's; event mode's 24-hour rule stays the Mac's (beta run 3, B3-01).
// - Then, while the band is red with the Mac's warning for home and the phone's own fresh reading finds no warning, the
//   band names the Mac's warning again and says which is newer in one line; in any red band the answer box's all-clear
//   is hidden by the style (beta run 3, B3-01).
//
// Only the forms of selector the front page's own script uses. The payload's HTML is the app's, every word from a
// feed escaped (LiveBlockTests); the Needs action line is built from text nodes.
(function () {
  'use strict';
  var HIDE = 'pm-hide';
  var LAPTOP = ['here-alerts', 'here-forecast'];  // the Mac's blocks for where the laptop is (dashboard/sources.py)

  function each(root, selector, fn) {
    var found = root.querySelectorAll(selector), i;
    for (i = 0; i < found.length; i++) fn(found[i]);
  }

  function kids(el) { return Array.prototype.slice.call(el.children); }

  function after(el) {
    var siblings = kids(el.parentNode);
    return siblings[siblings.indexOf(el) + 1] || null;
  }

  function time(el) {
    var age = el && el.querySelector('[data-at]');
    return age ? Date.parse(age.getAttribute('data-at')) : NaN;
  }

  function macBlock(root, sid) {
    var hit = null;
    each(root, '[data-source]', function (el) {
      if (!hit && el.getAttribute('data-source') === sid && !el.hasAttribute('data-pm-live')) hit = el;
    });
    return hit;
  }

  function hide(el) {
    if (!el || el.classList.contains(HIDE)) return;
    el.classList.add(HIDE);
    el.setAttribute('data-pm-was-hidden', el.hidden ? '1' : '0');
    el.hidden = true;
  }

  // hide()'s undoing: shown or hidden as it was before.
  function unhide(el) {
    el.classList.remove(HIDE);
    el.hidden = el.getAttribute('data-pm-was-hidden') === '1';
    el.removeAttribute('data-pm-was-hidden');
  }

  // A Mac block's cross-check lines (the alerts panel's), marked once so they travel with it.
  function followers(block) {
    var sid = block.getAttribute('data-source'), next = block.parentNode ? after(block) : null, found = [];
    while (next && next.classList.contains('box') && !next.hasAttribute('data-source')) {
      next.setAttribute('data-pm-after', sid);
      found.push(next);
      next = after(next);
    }
    each(document.getElementById('conditions'), '[data-pm-after]', function (el) {
      if (el.getAttribute('data-pm-after') === sid && found.indexOf(el) < 0) found.push(el);
    });
    return found;
  }

  // Moves a Mac block (with its followers) before `before` in `into`, leaving a marker where it first stood.
  function move(block, into, before) {
    var travelling = followers(block), marker;
    if (!block.hasAttribute('data-pm-moved')) {
      marker = document.createElement('span');
      marker.setAttribute('data-pm-home', block.getAttribute('data-source'));
      marker.hidden = true;
      block.parentNode.insertBefore(marker, block);
      block.setAttribute('data-pm-moved', '1');
    }
    into.insertBefore(block, before);
    travelling.forEach(function (el) { into.insertBefore(el, before); });
  }

  // The page as the Mac wrote it: every moved block back at its marker, the block and the phone's band lines and
  // marks gone, everything hidden shown again, the Mac's Needs action line back.
  function restore(s, p) {
    var old = document.getElementById('pm-live'), answer = s.querySelector('.answer');
    each(s, '[data-pm-home]', function (marker) {
      var block = macBlock(s, marker.getAttribute('data-pm-home'));
      if (block) {
        move(block, marker.parentNode, marker);
        block.removeAttribute('data-pm-moved');
      }
      marker.parentNode.removeChild(marker);
    });
    each(s, '[data-pm-placed]', function (el) {
      if (el.parentNode) el.parentNode.removeChild(el);
    });
    if (old && old.parentNode) old.parentNode.removeChild(old);
    each(s, '.' + HIDE, unhide);
    each(s, '.band .alert', function (el) {
      if (el.getAttribute('data-band-of') === 'pm-live') el.parentNode.removeChild(el);
    });
    each(s, '.ended-head', function (el) {  // the script's Ended line for a phone headline (B2-27)
      if (el.getAttribute('data-band-of') === 'pm-live') el.parentNode.removeChild(el);
    });
    each(s, '.band [data-pm-kind]', function (el) { el.parentNode.removeChild(el); });
    each(s, '[data-pm-at]', function (el) { el.removeAttribute('data-pm-at'); });  // counted()'s times
    each(s, '[data-pm-reads]', function (el) { el.removeAttribute('data-pm-reads'); });  // and marks
    each(s, '[data-pm-was-at]', function (el) {  // newest()'s times, the Mac's back
      el.setAttribute('data-at', el.getAttribute('data-pm-was-at'));
      el.removeAttribute('data-pm-was-at');
    });
    each(s, '[data-pm-was-t]', function (el) {
      el.setAttribute('data-t', el.getAttribute('data-pm-was-t'));
      el.removeAttribute('data-pm-was-t');
    });
    if (answer) {
      writeNeeds(answer, macNeeds(answer).needs.map(function (id) {
        return {href: '#panel-' + id, name: macNeeds(answer).names[id]};
      }), p);
    }
  }

  // The Mac's own Needs action line, read once, before the first rewrite.
  function macNeeds(answer) {
    var needs = [], names = {};
    if (!answer.hasAttribute('data-pm-mac-needs')) {
      each(answer, 'a[href^="#panel-"]', function (a) {
        var id = a.getAttribute('href').slice(7);
        needs.push(id);
        names[id] = a.textContent;
      });
      answer.setAttribute('data-pm-mac-needs', JSON.stringify({needs: needs, names: names}));
    }
    return JSON.parse(answer.getAttribute('data-pm-mac-needs'));
  }

  function writeNeeds(answer, links, p) {
    var said = answer.querySelector('.said'), line = document.createElement('p'), mark;
    if (!said) return;
    each(said, '.needs', function (el) { said.removeChild(el); });
    each(said, '.all-clear', function (el) { said.removeChild(el); });
    if (links.length) {
      line.className = 'needs';
      line.setAttribute('role', 'text');  // read as one piece, as the Mac's (Task 8.7, F61)
      // its spoken text, the words joined as they show (VoiceOver dropped the space before the first link; B2-17)
      line.setAttribute('aria-label', p.needsLine.split('{links}')[0] + links.map(function (link) {
        return link.name;
      }).join(', ') + p.needsLine.split('{links}')[1]);
      line.appendChild(document.createTextNode(p.needsLine.split('{links}')[0]));
      links.forEach(function (link, n) {
        var a = document.createElement('a');
        if (n) line.appendChild(document.createTextNode(', '));
        a.setAttribute('href', link.href);
        a.textContent = link.name;
        line.appendChild(a);
      });
      line.appendChild(document.createTextNode(p.needsLine.split('{links}')[1]));
    } else {
      line.className = 'all-clear';
      line.textContent = p.nothingNeeds;
    }
    said.insertBefore(line, said.children[0] || null);
    answer.classList.toggle('is-bad', links.length > 0);
    mark = answer.querySelector('.mark');
    if (mark) mark.textContent = links.length ? p.warnMark : answer.getAttribute('data-mark-ok');
  }

  function ownLimits(s, oldLine) {
    each(s, '[data-own-stale-hours]', function (el) {
      var own = el.getAttribute('data-own-stale-hours'), block = el.parentNode;
      if (el.getAttribute('data-stale-hours') === own) return;
      el.setAttribute('data-stale-hours', own);
      el.setAttribute('data-old', oldLine.replace('{n}', own));
      if (block) {  // the old line the Mac wrote for the floor: the page's script writes it again for this limit
        kids(block).forEach(function (child) {
          if (child.classList.contains('old-line')) block.removeChild(child);
        });
      }
    });
  }

  function marks(band, p) {
    Object.keys(p.eventEmoji).forEach(function (kind) {  // a mark for each kind of event the phone can start
      var there = false, mark;
      each(band, '[data-kind]', function (el) { if (el.getAttribute('data-kind') === kind) there = true; });
      if (there) return;
      mark = document.createElement('span');
      mark.className = 'em';
      mark.setAttribute('aria-hidden', 'true');
      mark.setAttribute('data-kind', kind);
      mark.setAttribute('data-pm-kind', '1');
      mark.hidden = true;
      mark.textContent = p.eventEmoji[kind];
      (band.querySelector('.marks') || band).appendChild(mark);
    });
  }

  // The whole-plan review: the guide button of each kind of event the phone's own warnings start (p.guides,
  // LiveBlock's, linked only to a guide the library holds), last among the band's first-aid buttons, where the Mac's
  // band doesn't link that guide already (its page was built before the warning, or the phone is away from home). The
  // page's own script shows it in event mode while its kind is on, as it does the Mac's; restore() takes it out.
  function guides(p, kinds) {
    var sos = document.getElementById('sos'), box;
    if (!sos || !p.guides) return;
    box = document.createElement('div');
    box.innerHTML = p.guides;
    kids(box).forEach(function (el) {
      var href = el.querySelector('a').getAttribute('href'), there = false;
      if (kinds.indexOf(el.getAttribute('data-kind')) < 0) return;
      each(sos, 'a', function (a) { if (a.getAttribute('href') === href) there = true; });
      if (there) return;
      el.setAttribute('data-pm-placed', '1');
      sos.appendChild(el);
    });
  }

  // Plan phase 9, item 9: in event mode (the page's own data-mode), the street map's rally points and routes are one tap
  // away, above What to do now. The app's own link (prepareme://streetmap); the App Store Kiwix never runs this script,
  // so its readers never see a link it can't follow. Only once the app says its map view is ready
  // (window.PrepareMeStreetMap, StreetMap.viewReady): a button to an unfinished screen helps nobody in an emergency.
  // Its own class: the page hides .now-link in event mode (review 2026-10-14).
  function streetMapLink(s) {
    var go, a, em, at, old = document.getElementById('pm-street-map');
    if (window.PrepareMeStreetMap !== true || document.getElementById('rally-line')) {  // the band's rally line instead
      if (old) old.parentNode.removeChild(old);
      return;
    }
    at = document.getElementById('band');
    if (old) {  // the band can come after it (a calm page that turns to event mode): it follows the band again
      if (at && at.parentNode && old.previousElementSibling !== at) at.parentNode.insertBefore(old, at.nextSibling);
      return;
    }
    go = document.createElement('p');
    go.id = 'pm-street-map';
    go.className = 'street-link';
    a = document.createElement('a');
    a.setAttribute('href', 'prepareme://streetmap');
    em = document.createElement('span');  // the map emoji is a picture: VoiceOver never reads it (Task 8.7, F61)
    em.className = 'em';
    em.setAttribute('aria-hidden', 'true');
    em.textContent = '\uD83D\uDDFA\uFE0F';
    a.appendChild(em);
    a.appendChild(document.createTextNode('Street map: meeting places and routes'));
    go.appendChild(a);
    // Right after the band in the page's own order, where it shows in event mode, so VoiceOver reads it there too
    // (Task 8.7, F61); a page with no band keeps the place above What to do now.
    if (at && at.parentNode) at.parentNode.insertBefore(go, at.nextSibling);
    else if ((at = s.querySelector('.now-link'))) at.parentNode.insertBefore(go, at);
    else s.insertBefore(go, s.children[1] || null);
  }

  // Beta run 2, R9.1 (mockup 1): the band's rally line ("Where we meet: Maps › Street map", written with no place in
  // it) becomes the street map's link once the app says its map view is ready, naming the rally point the map points
  // to when the app knows it (p.rally, from its copy of the lists: on the phone only, never in the library). Its own
  // line in the built one's place, which is hidden, so restore() puts the page back as built.
  function rallyLine(p) {
    var built = document.getElementById('rally-line'), line, a, em, words = '', i;
    if (!built || window.PrepareMeStreetMap !== true) return;
    for (i = 0; i < built.childNodes.length; i++) {
      if (built.childNodes[i].nodeType === 3) words += built.childNodes[i].textContent;
    }
    if (p.rally) words = p.rallyNamed.split('{name}').join(p.rally);
    line = document.createElement('p');
    line.id = 'pm-rally';
    line.className = 'rally';
    line.setAttribute('data-pm-placed', '1');
    a = document.createElement('a');
    a.setAttribute('href', 'prepareme://streetmap');
    em = document.createElement('span');  // a picture: VoiceOver never reads it
    em.className = 'em';
    em.setAttribute('aria-hidden', 'true');
    em.textContent = '\uD83D\uDCCD';
    a.appendChild(em);
    a.appendChild(document.createTextNode(words));
    line.appendChild(a);
    built.parentNode.insertBefore(line, built.nextSibling);
    hide(built);
  }

  // Which panels need action, for the answer box's line: a live panel when a phone block in it says so, or when the
  // Mac's line said so and a Mac block still standing in it needs action itself (data-needs; any Mac block on a page
  // without data-needs-marked, from before the Mac marked them): FEMA's block for elsewhere no longer keeps the
  // panel red once the phone's own alerts reading has dropped the Mac's warning (phase 5 review, I3). Any other
  // panel as the Mac's line said. Each live panel's card class follows.
  function needed(answer, p) {
    var bad = [], mac = answer ? macNeeds(answer) : {needs: [], names: {}},
      top = document.getElementById('conditions'), marked = !!top && top.hasAttribute('data-needs-marked');
    p.order.forEach(function (id) {
      var panel = document.getElementById('pm-panel-' + id), mine = false, macs = false,
        said = mac.needs.indexOf(id) >= 0, need;
      if (p.panels.indexOf(id) < 0 || !panel) {
        if (said) bad.push({href: '#panel-' + id, name: mac.names[id]});
        return;
      }
      each(panel, '[data-source]', function (el) {
        if (el.hasAttribute('data-pm-live')) mine = mine || el.hasAttribute('data-pm-needs');
        else macs = macs || !marked || el.hasAttribute('data-needs');
      });
      need = mine || (said && macs);
      panel.classList.toggle('card', need);
      if (need) bad.push({href: '#pm-panel-' + id, name: p.headings[id]});
    });
    return bad;
  }

  function placed(el) { el.setAttribute('data-pm-placed', '1'); }

  // A panel's or a row's id in the page's panel order ("pm-panel-power", "row-power": "power").
  function idOf(el) { return el.id.replace(/^pm-/, '').replace(/^(panel|row)-/, ''); }

  // Puts `el` in `box` before the first of its children that comes later in the page's panel order.
  function inOrder(box, el, p) {
    var at = null, mine = p.order.indexOf(idOf(el));
    kids(box).forEach(function (other) {
      if (!at && other.id && p.order.indexOf(idOf(other)) > mine) at = other;
    });
    box.insertBefore(el, at);
  }

  // Where a part made here goes when the page has no box of its kind (the owner's fixes 6 and 7, 2026-10-16): the
  // red cards over the weather (its alerts worth a look, else the forecast strip's fold); the weather's alerts worth a
  // look over the strip; any other part under the answer box. Each falls back to the next place there is.
  function before(s, el, where) {
    var answer = s.querySelector('.answer'), strip = document.getElementById('fold-strip'),
      at = where === 'cards' ? document.getElementById('worth-weather') || document.getElementById('pm-worth-weather')
        || strip : where === 'weather' ? strip : null;
    if (at) at.parentNode.insertBefore(el, at);
    else if (answer) answer.parentNode.insertBefore(el, after(answer));
    else if (strip) strip.parentNode.insertBefore(el, strip);
    else s.appendChild(el);
  }

  function intoCards(s, panel, p) {
    var cards = s.querySelector('.problems');
    if (!cards) {  // made as the page's own script makes it: left in place, empty, when the page is put back
      cards = document.createElement('div');
      cards.className = 'problems';
      before(s, cards, 'cards');
    }
    cards.hidden = false;
    placed(panel);
    inOrder(cards, panel, p);
  }

  // Worth a look: the weather's alerts in their own group over the 4-day boxes (fix 7), any other panel in the group
  // headed Worth a look under the answer box.
  function intoWorth(s, panel, p) {
    var weather = p.weatherWorth.indexOf(idOf(panel)) >= 0, id = weather ? 'worth-weather' : 'worth',
      group = document.getElementById(id) || document.getElementById('pm-' + id), title, em;
    if (!group) {
      group = document.createElement('div');
      group.className = 'worth';
      group.id = 'pm-' + id;
      placed(group);
      if (!weather) {
        title = document.createElement('p');
        title.className = 'group worth-title';
        em = document.createElement('span');
        em.className = 'em';
        em.setAttribute('aria-hidden', 'true');
        em.textContent = p.lookMark;
        title.appendChild(em);
        title.appendChild(document.createTextNode(p.worth));
        group.appendChild(title);
      }
      before(s, group, weather ? 'weather' : 'other');
    }
    placed(panel);
    inOrder(group, panel, p);
  }

  // The Today redesign's phase 3: each live panel where the Mac's page would put it. A card when it needs action;
  // worth a look when the phone's own readings say so (LiveBlock heads it with its row's words), or when the Mac's
  // panel was worth a look and a Mac block still stands in it; else a condition row: while any of its feeds is the
  // Mac's copy ("mac"), the panel in the Mac's own row, whose words are the Mac's; otherwise the phone's own row, its
  // words from the phone's readings, where the Mac's stood. The forecast goes in its fold under Details. The block
  // keeps its group and note, in Sources and ages at the page's end. Each part placed is marked for restore().
  function placeAll(s, block, p) {
    var srcs = s.querySelector('.ages .srcs'), rowsFold = document.getElementById('fold-conds'),
      rowsBox = rowsFold && rowsFold.querySelector('.conds');  // the condition rows' own box, not the forecast's
    kids(block).forEach(function (el) {
      var id = el.getAttribute('data-pm-row'), status = el.getAttribute('data-pm-status'), panel, macRow, macPanel,
        stands = false, fold, mac;
      if (el.id === 'pm-panel-forecast') {
        fold = document.getElementById('fold-forecast');
        mac = document.getElementById('panel-forecast');
        placed(el);
        if (fold) fold.insertBefore(el, mac && mac.parentNode === fold ? mac : null);
        else before(s, el, 'weather');
        return;
      }
      if (!id) return;
      panel = document.getElementById('pm-panel-' + id);
      macRow = document.getElementById('row-' + id);
      macPanel = document.getElementById('panel-' + id);
      each(panel, '[data-source]', function (src) { if (!src.hasAttribute('data-pm-live')) stands = true; });
      block.removeChild(el);
      if (panel.classList.contains('card')) {
        el.removeChild(panel);
        intoCards(s, panel, p);
        hide(macRow);
      } else if (status === 'look' || (status === 'mac' && stands && macPanel && macPanel.classList.contains('look'))) {
        el.removeChild(panel);
        panel.classList.add('look');
        intoWorth(s, panel, p);
        hide(macRow);
      } else if (status === 'mac' && macRow) {
        el.removeChild(panel);
        placed(panel);
        macRow.appendChild(panel);
      } else {
        placed(el);
        if (macRow) macRow.parentNode.insertBefore(el, macRow);
        else if (rowsBox) inOrder(rowsBox, el, p);
        else before(s, el);
        hide(macRow);
      }
    });
    if (srcs) srcs.appendChild(block);
  }

  // The outage count's card in event mode (owner, 2026-10-07): the phone's power panel follows the Mac's, which the
  // page's own script has just placed for the mode, and its row hides. Placed again at the next call.
  function power(s, p) {
    var mine = document.getElementById('pm-panel-power'), mac = document.getElementById('panel-power'),
      row = mine && mine.parentNode;
    if (!mine || !mac || !mac.classList.contains('card') || mine.classList.contains('card')) return;
    mine.classList.add('card');
    intoCards(s, mine, p);
    if (row && row.id === 'pm-row-power') hide(row);
  }

  // The count over the rows (OTHER_CONDITIONS), of the ones that show.
  function count(s) {
    var title = document.getElementById('conds-title'), n = 0;
    if (!title) return;
    each(s, '.row.cond', function (row) { if (!row.hidden && !row.classList.contains('tally')) n++; });
    title.textContent = title.getAttribute('data-tpl').replace('{n}', String(n));
  }

  // Where this phone is (step 6, part 4): the phone's own sunrise, sunset and dark, worked out on the phone from
  // where it is (never kept), at the end of the sky's lines when any of the three is p.sky.apart minutes or more from
  // home's for the phone's own date (data-sky-at, minutes after midnight), so a phone at home shows home's alone.
  // Its date is the phone's, not the page's home date the page's own script shows home's lines by, so it carries no
  // data-sky-day and that script leaves it alone (a phone in Hawaii in the evening is a day behind home: the review).
  // Without home's line for that date (the Mac's page older than its sky days), the phone's line shows alone and the
  // box with it (offline fixes, task 4.3; the page's own script hides the box only when nothing in it shows). Put
  // back at each call.
  function skyHere(p) {
    var box = document.getElementById('sky'), old = document.getElementById('sky-here'), home, theirs, apart = false,
      line, mark;
    if (old) old.parentNode.removeChild(old);
    if (!p.sky || !box) return;
    each(box, '[data-sky-at]', function (el) {
      if (el.getAttribute('data-sky-day') === p.sky.day) home = el;
    });
    if (home) {
      theirs = home.getAttribute('data-sky-at').split(' ');
      p.sky.at.forEach(function (mine, n) {
        var at = theirs[n] === '-' || theirs[n] === undefined ? null : Number(theirs[n]);
        if ((mine === null) !== (at === null) || (mine !== null && Math.abs(mine - at) >= p.sky.apart)) apart = true;
      });
      if (!apart) return;
    }
    line = document.createElement('p');
    line.id = 'sky-here';
    mark = document.createElement('span');
    mark.className = 'em';
    mark.setAttribute('aria-hidden', 'true');
    mark.textContent = '\ud83d\udccd';
    line.appendChild(mark);
    line.appendChild(document.createTextNode(p.sky.line));
    box.appendChild(line);
    box.hidden = false;
  }

  // Offline fixes, task 3.2: the app's line when its inventory copy, or its last reach of the Mac, is over 3 days old,
  // last of the quiet notes at the page's end (beside the lists' as-of line); taken out again when the app sends none.
  function inventoryAge(s, p) {
    var old = document.getElementById('pm-inventory-age'), line;
    if (old) old.parentNode.removeChild(old);
    if (!p.inventoryAge) return;
    line = document.createElement('p');
    line.id = 'pm-inventory-age';
    line.className = 'note';
    line.textContent = p.inventoryAge;
    (s.querySelector('.quiet') || s).appendChild(line);
  }

  // Beta run 3, B3-01: each of the Mac's main readings (data-core) of a feed the phone shows its own reading of (live:
  // read within its 2 hours, or newer than the Mac's copy) counts in the page's oldest-reading line and its 12-hour
  // banner, in the answer box and the band, at the phone's reading's time (data-pm-at, which the page's own script
  // reads in its place, every minute too), so a panel the phone read fresh never reads as old there, and the line
  // names what is actually oldest. Per feed: a panel's feed the phone couldn't read still counts at the Mac's time.
  // Event mode's 24-hour rule counts the phone's times too (offline fixes, task 4.2, the owner's answer 2, replacing
  // B3-01's ruling), and data-pm-reads marks every feed the phone reads, for the banner's Mac-only form. The Mac's
  // data-at and data-core stay, so its block's own age is the Mac's. restore() takes the times and marks off.
  function counted(s, live, covered) {
    covered.forEach(function (sid) {
      var mac = macBlock(s, sid);
      if (mac) each(mac, '[data-core]', function (el) { el.setAttribute('data-pm-reads', '1'); });
    });
    each(s, '[data-pm-live]', function (mine) {
      var sid = mine.getAttribute('data-source'), mac = macBlock(s, sid), at = mine.querySelector('[data-at]');
      if (!mac || !at || live.indexOf(sid) < 0) return;
      each(mac, '[data-core]', function (el) { el.setAttribute('data-pm-at', at.getAttribute('data-at')); });
    });
  }

  // Sources and ages (owner, 2026-10-28): a feed the phone shows its own reading of gives the newer of that reading's
  // time and the Mac's copy's, so the list says how current each feed is. A line that stands for several feeds (the
  // gauges: data-age-of names each) gives the newest of all their times, as the Mac's gives the newest of its own.
  // Only the times change (data-at, data-t): the page's own script writes the words and judges the age by the source's
  // own limit. restore() puts the Mac's back.
  function newest(s, live) {
    each(s, '[data-age-of]', function (li) {
      var sids = li.getAttribute('data-age-of').split(' '), age = li.querySelector('[data-at]'),
        t = age && age.querySelector('[data-t]'), at = NaN, from = null;
      if (!t || !sids.some(function (sid) { return live.indexOf(sid) >= 0; })) return;
      sids.forEach(function (sid) {
        if (live.indexOf(sid) < 0) return;  // a Mac-only feed's time is in the line already
        each(s, '[data-pm-live]', function (el) {
          if (el.getAttribute('data-source') === sid && (time(el) > at || isNaN(at))) { at = time(el); from = el; }
        });
      });
      if (!from || !(at > time(li))) return;
      age.setAttribute('data-pm-was-at', age.getAttribute('data-at'));
      t.setAttribute('data-pm-was-t', t.getAttribute('data-t'));
      age.setAttribute('data-at', from.querySelector('[data-at]').getAttribute('data-at'));
      t.setAttribute('data-t', age.getAttribute('data-at'));
    });
  }

  // The band's headlines from `sid` whose own end time has passed.
  function endedAlerts(band, sid) {
    var found = [];
    each(band, '.alert', function (el) {
      var end = el.querySelector('[data-expires]');
      if (el.getAttribute('data-band-of') !== sid || !end) return;
      if (Date.now() >= Date.parse(end.getAttribute('data-expires'))) found.push(el);
    });
    return found;
  }

  // A copy of one of the page's time spans (data-t), which the page's own script writes again as it writes them all.
  function timeSpan(from) {
    var span = document.createElement('span');
    span.className = 't';
    span.setAttribute('data-t', from.getAttribute('data-t'));
    span.textContent = from.textContent;
    return span;
  }

  // Beta run 3, B3-01 (the owner's answer a): the band is red (the page's own mode), the Mac's page carries a warning
  // for home whose own end hasn't passed, and this phone's fresh reading of home's alerts finds none (p.homeNoneAt,
  // LiveBlock's; a reading older than the Mac's copy gave way to it above, so it isn't live here). The band keeps all
  // the Mac's page set (its marks, buttons and event mode) and adds one line, p.disagree, ahead of the first-aid
  // buttons, the two times as the page's own time spans (data-t: the page's script keeps them in its format): the
  // phone's reading's and the Mac's alerts reading's (the page carries no time of its own writing). The Mac's warning
  // headline, which the hide pass above took out of the band, shows again with its instruction (the owner's ruling: a
  // warning stays named on Today until its own end time), the line after it. The answer box's all-clear goes in any
  // red band, by the style (#pm-live-style). restore() takes the line out; the headline is the page's as built. The
  // band's data-pm-shown says the home headline is shown, so apply() keeps its Ended line when the warning ends.
  // F-093 (the owner's click, 2026-10-21): an evacuation order for home gets the same, from p.evacNoneAt and its own
  // words, its line after the warning's.
  function disagree(s, live, p) {
    var band = document.getElementById('band');
    if (band) band.removeAttribute('data-pm-shown');  // set again below while this payload shows the headline
    if (!band || s.getAttribute('data-mode') !== 'event') return;
    if (disagreeOn(s, band, live, 'home-alerts', p.homeNoneAt, p.disagree)) {
      band.setAttribute('data-pm-shown', '1');  // its Ended line, when the page's minute pass makes one, is kept
    }
    disagreeOn(s, band, live, 'evacuations', p.evacNoneAt, p.evacDisagree);
  }

  // disagree() for one source `sid` the phone read itself (`noneAt`: its fresh reading found nothing for home), with
  // its line's `template`: whether the Mac's headline was shown with the line.
  function disagreeOn(s, band, live, sid, noneAt, template) {
    var mac = macBlock(s, sid), sos = document.getElementById('sos'), warned = [], mine = null, macAt, mineAt, line,
      words;
    if (!mac || !noneAt || !template || live.indexOf(sid) < 0) return false;
    each(band, '.alert', function (el) {
      var end = el.querySelector('[data-expires]');
      if (el.getAttribute('data-band-of') !== sid) return;
      if (!end || !(Date.now() >= Date.parse(end.getAttribute('data-expires')))) warned.push(el);
    });
    each(s, '[data-pm-live]', function (el) { if (el.getAttribute('data-source') === sid) mine = el; });
    macAt = mac.querySelector('[data-at] .t');
    mineAt = mine && mine.querySelector('[data-at] .t');
    words = template.split('{mine}');
    if (!warned.length || !macAt || !mineAt || words.length < 2) return false;
    words = [words[0]].concat(words[1].split('{mac}'));
    if (words.length < 3) return false;
    warned.forEach(unhide);  // shown as built: restore() has nothing to put back
    line = document.createElement('p');
    line.className = 'pm-disagree';
    line.setAttribute('data-pm-of', sid);
    placed(line);
    line.appendChild(document.createTextNode(words[0]));
    line.appendChild(timeSpan(mineAt));
    line.appendChild(document.createTextNode(words[1]));
    line.appendChild(timeSpan(macAt));
    line.appendChild(document.createTextNode(words[2]));
    band.insertBefore(line, sos && sos.parentNode === band ? sos : null);
    return true;
  }

  function apply(p) {
    var s = document.getElementById('conditions'), box, block, answer, band, banner, style, covered, live, kinds,
      ended, ending = [], bad = [];
    if (!s) return false;
    // Where the page is read (the Today redesign): the app marked it "phone" before it drew; a read-only phone's
    // Event mode is an adult's to switch, so its direction differs.
    if (p.host) document.documentElement.setAttribute('data-host', p.host);
    if (!document.getElementById('pm-live-style')) {
      style = document.createElement('style');
      style.id = 'pm-live-style';
      style.textContent = '#conditions .' + HIDE + '{display:none!important}' +
        '#conditions:not([data-mode="event"]) #pm-street-map{display:none}' +
        // after the date line (-5) and the band (-4), before the answer box (-1) and What to do now (order 1) (second
        // review, 2026-10-14)
        '#conditions[data-mode="event"] #pm-street-map{order:-2}' +
        '#pm-street-map{margin:.75em 0;font-size:1.1em;font-weight:600}' +
        // B3-01's line, across the red band; in event mode only, as the band
        '#conditions .band>.pm-disagree{grid-column:1/-1;margin:0;font-weight:700}' +
        '#conditions:not([data-mode="event"]) .pm-disagree{display:none}' +
        // no green Nothing needs action under a red band (B3-01, the owner's rule for every red band): the style
        // follows the mode as the page's own script sets it
        '#conditions[data-mode="event"] .answer:not(:has(.needs)){display:none}' +
        // the inventory age line (offline fixes, task 3.2), amber as the quiet notes' banner
        '#pm-inventory-age{color:var(--caution);font-weight:700}';
      s.insertBefore(style, s.children[0] || null);
    }
    streetMapLink(s);
    answer = s.querySelector('.answer');
    if (answer) macNeeds(answer);
    restore(s, p);
    rallyLine(p);
    ownLimits(s, p.oldLine);
    skyHere(p);
    inventoryAge(s, p);
    if (!p.html) {
      band = document.getElementById('band');
      if (band) band.removeAttribute('data-pm-shown');
      window.dispatchEvent(new Event('focus'));
      return true;
    }
    box = document.createElement('div');
    box.innerHTML = p.html;
    block = box.children[0];
    // A phone reading older than the Mac's copy of the same feed stands aside for it (review C1).
    each(block, '[data-pm-live]', function (mine) {
      var mac = macBlock(s, mine.getAttribute('data-source')), note;
      if (!mac || !(time(mac) > time(mine))) return;
      note = document.createElement('p');
      note.className = 'note pm-why';
      note.textContent = p.macNewer;
      mine.parentNode.insertBefore(note, after(mine));
      move(mac, mine.parentNode, mine);
      mine.parentNode.removeChild(mine);
    });
    covered = [];
    each(block, '[data-source]', function (el) { covered.push(el.getAttribute('data-source')); });
    each(block, '[data-pm-mac]', function (slot) {
      var mac = macBlock(s, slot.getAttribute('data-pm-mac'));
      covered.push(slot.getAttribute('data-pm-mac'));
      if (!mac) return;  // the slot's own line says the Mac's copy doesn't have it either
      move(mac, slot.parentNode, slot);
      slot.parentNode.removeChild(slot);
    });
    each(block, '[data-pm-rest]', function (slot) {
      var panel = document.getElementById('panel-' + slot.getAttribute('data-pm-rest')), rest = [];
      if (panel) each(panel, '[data-source]', function (el) { rest.push(el); });
      rest.forEach(function (el) {
        var sid = el.getAttribute('data-source');
        if (covered.indexOf(sid) < 0 && LAPTOP.indexOf(sid) < 0) move(el, slot.parentNode, slot);
      });
    });
    if (answer && answer.parentNode) answer.parentNode.insertBefore(block, after(answer));
    else s.insertBefore(block, s.children[0] || null);
    live = [];
    each(block, '[data-pm-live]', function (el) { live.push(el.getAttribute('data-source')); });
    p.panels.forEach(function (id) { hide(document.getElementById('panel-' + id)); });
    bad = needed(answer, p);
    placeAll(s, block, p);
    each(s, '.problems', function (cards) {  // a cards box whose every card is hidden goes too
      if (kids(cards).every(function (card) { return card.classList.contains(HIDE); })) hide(cards);
    });
    // And the Worth a look group (the Today redesign's phase 2) once every panel in it is hidden.
    each(s, '.worth', function (group) {
      if (kids(group).every(function (el) {
        return el.classList.contains(HIDE) || !/(^|-)panel-/.test(el.id);
      })) {
        hide(group);
      }
    });
    band = document.getElementById('band');
    if (band) {
      // A home headline disagree() was showing whose end has passed before the page's minute pass came stays shown,
      // so the page's pass below (the focus) makes its Ended line, kept like the minute's (the final review's race).
      ending = band.hasAttribute('data-pm-shown') && p.homeNoneAt ? endedAlerts(band, 'home-alerts') : [];
      each(band, '.alert', function (el) {
        var of = el.getAttribute('data-band-of');
        if (ending.indexOf(el) < 0 && (live.indexOf(of) >= 0 || LAPTOP.indexOf(of) >= 0)) hide(el);
      });
      // and the Ended line the page's own pass made of a Mac headline before this payload came (the page opened after
      // the warning's end): the phone's copy of the alert makes its own (checkpoint 1). Put back by restore(). But an
      // Ended line the page made since the last payload, while disagree() was showing the Mac's home headline
      // (data-pm-shown on the band; a hidden headline ends with no line), is that warning's end under the phone's
      // line: it is kept (data-pm-kept), so the warning goes from named to Ended and stays so (final review).
      each(s, '.ended-head', function (el) {
        var of = el.getAttribute('data-band-of');
        if (of === 'pm-live') return;
        if (of === 'home-alerts' && !el.hasAttribute('data-pm-seen') && band.hasAttribute('data-pm-shown')) {
          el.setAttribute('data-pm-kept', '1');
        }
        el.setAttribute('data-pm-seen', '1');
        if (!el.hasAttribute('data-pm-kept') && (live.indexOf(of) >= 0 || LAPTOP.indexOf(of) >= 0)) hide(el);
      });
      box = document.createElement('div');
      box.innerHTML = p.band;
      banner = document.getElementById('band-banner');
      kinds = [];
      kids(box).forEach(function (el) {
        var shown = false;
        if (live.indexOf(el.getAttribute('data-pm-src')) >= 0) kinds.push(el.getAttribute('data-band-kind'));
        each(band, '.alert', function (other) {
          if (!other.hidden && other.textContent === el.textContent) shown = true;
        });
        // with the band's other headlines, ahead of the first-aid buttons (R9.1); on an older page, before the banner
        if (live.indexOf(el.getAttribute('data-pm-src')) >= 0 && !shown) {
          band.insertBefore(el, document.getElementById('sos') || banner);
        }
      });
      marks(band, p);
      guides(p, kinds);  // after the marks: a guide button's data-kind isn't a mark
    }
    if (answer) writeNeeds(answer, bad, p);
    counted(s, live, covered);
    newest(s, live);
    window.dispatchEvent(new Event('focus'));  // the page's own script: ages, the banner, the mode
    if (ending.length) {
      each(s, '.ended-head', function (el) {
        if (el.getAttribute('data-band-of') !== 'home-alerts' || el.hasAttribute('data-pm-seen')) return;
        el.setAttribute('data-pm-kept', '1');
        el.setAttribute('data-pm-seen', '1');
      });
    }
    ended = [];  // the phone's own Ended line, when its copy of an alert ended, is the one, as above
    each(s, '.ended-head', function (el) { ended.push(el); });
    if (ended.some(function (el) { return el.getAttribute('data-band-of') === 'pm-live'; })) {
      ended.forEach(function (el) { if (el.hasAttribute('data-pm-kept')) hide(el); });
    }
    disagree(s, live, p);  // after the mode: only while the band is red
    power(s, p);
    count(s);
    return true;
  }

  // Offline fixes, task 4.1: the time of the Mac's copy of each source on the page (its first block's data-at), for
  // the app to choose the phone's own reading while it is newer than the Mac's copy.
  function macTimes() {
    var s = document.getElementById('conditions'), found = {};
    if (s) each(s, '[data-source]', function (el) {
      var sid = el.getAttribute('data-source'), age = el.querySelector('[data-at]');
      if (!el.hasAttribute('data-pm-live') && !(sid in found) && age) found[sid] = age.getAttribute('data-at');
    });
    return found;
  }

  window.PrepareMeLive = {apply: apply, macTimes: macTimes};
})();
