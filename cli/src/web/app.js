// Cinematheque's web client: browses the library its server shares, and
// plays from its sources. The server is this device; what's watched, and
// lists, are its person's.
"use strict";

const main = document.getElementById("main");
const search = document.getElementById("search");
const orderMenu = document.getElementById("order");
const grouping = document.getElementById("grouping");
const sidebarLists = document.getElementById("sidebar-lists");
const shelfTitle = document.getElementById("shelf-title");
const statusBar = document.getElementById("status");

/// Whether the window's wide enough for the sidebar, else it has the tab
/// bar, as app.css's media query has it.
const wide = matchMedia("(min-width: 768px)");

/// What the server last said: tiles; this person's lists, by name, each
/// with its titles' keys; and every key on any list.
let library = { tiles: [], lists: [], mine: [], listed: new Set(), shown: new Set() };

async function api(name, body) {
  const response = await fetch("api/" + name, body === undefined ? {} : {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${name}: ${response.status} ${await response.text()}`);
  return response.json();
}

/// The status line: the shelf's counts, which fade out 3 seconds after they
/// last changed and come back when the pointer nears the bottom, as the
/// Mac's status bar does; or a problem, which stays until something else
/// replaces it.
let fading = null;
let problemShown = false;

function show(text) {
  problemShown = false;
  if (statusBar.textContent !== text) statusBar.textContent = text || "";
  wake();
}

function problem(text) {
  problemShown = true;
  statusBar.textContent = text;
  wake();
}

function wake() {
  statusBar.classList.remove("faded");
  clearTimeout(fading);
  if (!problemShown) fading = setTimeout(() => statusBar.classList.add("faded"), 3000);
}

addEventListener("pointermove", (e) => {
  if (e.clientY > innerHeight - 60 && statusBar.classList.contains("faded")) wake();
});

/// Reads the library again, then shows the page again with it.
async function refresh() {
  await reload();
  route();
}

async function reload() {
  const [got, kept] = await Promise.all([api("tiles"), api("downloads").catch(() => ({ enabled: false }))]);
  const lists = got.lists.map((l) => ({ ...l, titles: new Set(l.titles) }));
  // This person's own, which they change, and mark titles as on a list;
  // then other members' shared ones, shown, but theirs to change.
  const mine = lists.filter((l) => l.mine);
  library = {
    tiles: got.tiles, lists, mine,
    listed: new Set(mine.flatMap((l) => [...l.titles])),
    // On any list shown, others' too, as the Lists shelf counts them.
    shown: new Set(lists.flatMap((l) => [...l.titles])),
  };
  // The sidebar's: this person's lists, then other members' shared ones.
  sidebarLists.replaceChildren(...lists.map((l) => el("a", { href: `#lists/${l.id}`, "data-shelf": `lists/${l.id}` }, listLabel(l))));
  markShown();
  noteDownloads(kept);
}

// Tiles.

/// A tile's key on a list: a movie's title key, or `<key>#<season>`.
function listKey(tile) { return tile.season == null ? tile.key : `${tile.key}#${tile.season}`; }

function coverURL(cover) {
  const q = new URLSearchParams({ url: cover.url, offset: cover.offset, length: cover.length, stamp: cover.stamp });
  return "api/cover?" + q;
}

function thumbURL(hash) { return "api/thumb?" + new URLSearchParams({ hash }); }

function el(tag, attributes = {}, ...children) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attributes)) {
    if (v == null || v === false) continue;
    if (k === "class") e.className = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else e.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) if (c != null) e.append(c);
  return e;
}

/// Covers and placeholders are fetched only as their tiles near the screen:
/// a shelf of thousands asked for them all at once, and the browser's few
/// connections to the server queued them behind one another. A tile that
/// leaves before its cover starts loading gives up its turn.
const nearScreen = new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (e.isIntersecting) e.target.near();
    else covers.waiting.delete(e.target);
  }
}, { rootMargin: "1000px 0px" });

/// Covers come from sources through the server, which waits on a NAS's
/// disks as they wake: so a few at a time, nearest the screen first, never
/// all of the browser's six connections to the server, which placeholders,
/// pages, and playing need meanwhile (a page opened while a shelf's covers
/// waited took 20 seconds). A page left behind abandons its covers.
const covers = { waiting: new Set(), loading: new Set(), most: 3 };

function nextCovers() {
  while (covers.loading.size < covers.most && covers.waiting.size) {
    let best = null;
    let nearest = Infinity;
    for (const c of covers.waiting) {
      if (!c.isConnected) { covers.waiting.delete(c); continue; }
      const r = c.getBoundingClientRect();
      const away = r.bottom < 0 ? -r.bottom : Math.max(0, r.top - innerHeight);
      if (away < nearest) { nearest = away; best = c; }
    }
    if (!best) return;
    covers.waiting.delete(best);
    best.fetchCover();
  }
}

/// Stops loading the covers of tiles no longer shown.
function abandonCovers() {
  for (const img of covers.loading) if (!img.isConnected) img.stop();
}

/// A list's placeholders not in the library yet, as tiles of their own: a
/// title put on it by name, keyed as its file will be, whose own tile takes
/// its place as it comes.
function placeholders(l) {
  // As lists key them: a movie's title key, a season's `<key>#<season>`.
  const present = new Set(library.tiles.map(listKey));
  return (l.wanted || []).filter((w) => !present.has(w.key)).map((w) => {
    const [key, season] = w.key.split("#");
    const year = Number(key.split("/").at(-1));
    return { key, name: w.name, year: year || null, kind: key.startsWith("t/s/") ? "series" : "movie", season: season == null ? null : Number(season),
      wanted: w.note, wantedKey: w.key, order: {}, watched: false, progress: 0, started: false };
  });
}

/// A placeholder's tile: dimmed, saying it's not in the library, its note
/// an article's address to open, if it is one, and a button taking it off
/// this person's lists, if it's on any.
function wantedView(tile, underSeries) {
  const link = /^https?:\/\//.test(tile.wanted) ? tile.wanted : null;
  const on = library.mine.filter((l) => (l.wanted || []).some((w) => w.key === tile.wantedKey));
  const a = el(link ? "a" : "div", { class: `tile wanted${tile.season == null ? "" : " season"}`, style: `--shape:${shapeOf(tile)}`, ...(link ? { href: link, target: "_blank", rel: "noopener" } : {}), title: tile.wanted || "Not in the library yet" },
    coverView(tile, underSeries ? seasonName(tile.season) : tile.name),
    el("div", { class: "name" }, underSeries ? seasonName(tile.season) : tile.name),
    el("div", { class: "sub split" }, el("span", {}, "Not in library"),
      on.length ? el("span", {},
        el("button", { class: "mark", type: "button", title: "Edit", "aria-label": `Edit ${tile.name}`, onclick: (e) => {
          e.preventDefault();
          askWanted(on, tile);
        } }, "✎"),
        el("button", { class: "mark", type: "button", title: "Remove from list", "aria-label": `Remove ${tile.name} from the list`, onclick: async (e) => {
          e.preventDefault();
          for (const l of on) await api("listed", { list: l.id, key: tile.wantedKey, on: false });
          await refresh();
        } }, "✕")) : ""));
  a.tileId = idOf(tile);
  a.underSeries = underSeries;
  a.looks = looks(tile);
  return a;
}

/// A tile; under its series' name (`underSeries`), a season says only which.
function tileView(tile, underSeries = false) {
  if (tile.wanted != null) return wantedView(tile, underSeries);
  const href = "#title/" + encodeURIComponent(tile.key) + (tile.season == null ? "" : "/" + tile.season);
  // Its shape for a carousel; a grid's cells are the column's.
  const lists = listsOf(listKey(tile));
  const a = el("a", { class: `tile${tile.season == null ? "" : " season"}${tile.unavailable ? " unavailable" : ""}`, href, style: `--shape:${shapeOf(tile)}` },
    coverView(tile, underSeries ? seasonName(tile.season) : tile.name),
    el("div", { class: "name-row" }, el("span", { class: "name" }, underSeries ? seasonName(tile.season) : tile.name), marksView(tile, lists)),
    underSeries ? null : el("div", { class: "sub" }, tile.season == null ? (tile.year ? String(tile.year) : "") : seasonName(tile.season)),
  );
  // What it was drawn from, to draw it again if that changes (see `patch`).
  a.tileId = idOf(tile);
  a.underSeries = underSeries;
  a.looks = looks(tile);
  return a;
}

/// A tile's identity, or a series' (its seasons'), for a shelf's makeup.
function idOf(item) {
  return item.seasons ? `${item.key}:${item.seasons.map(idOf).join(",")}` : `${item.key}#${item.season ?? ""}`;
}

/// What a tile shows of its data: its name and year, cover, marks, and
/// lists; changed, it's drawn again.
function looks(t) {
  return JSON.stringify([t.name, t.year, t.cover, t.thumb, t.watched, t.progress, t.unavailable, listsOf(listKey(t)).map((l) => l.id)]);
}

/// Covers' shapes, width over height: nearly all are a poster's (2:3) or
/// square (a season's, often); a few, a TV's.
const shapes = [2 / 3, 1, 4 / 3, 16 / 9];

/// The shape nearest `ratio`.
function nearestShape(ratio) {
  return shapes.reduce((a, b) => Math.abs(Math.log(b / ratio)) < Math.abs(Math.log(a / ratio)) ? b : a);
}

/// A tile's shape, for a carousel to size it before its cover loads: its
/// placeholder's (a ThumbHash keeps its image's approximate width over
/// height, as the core's `thumbhash.aspectRatio` reads it), else a movie's
/// 2:3 or a season's square.
function shapeOf(tile) {
  if (tile.thumb && tile.thumb !== "-") {
    try {
      const h = Uint8Array.from(atob(tile.thumb), (c) => c.charCodeAt(0));
      const alpha = (h[2] & 0x80) !== 0, landscape = (h[4] & 0x80) !== 0;
      const lx = landscape ? (alpha ? 5 : 7) : h[3] & 7;
      const ly = landscape ? h[3] & 7 : (alpha ? 5 : 7);
      if (lx && ly) return nearestShape(lx / ly);
    } catch { /* No placeholder to go by. */ }
  }
  return tile.season == null ? 2 / 3 : 1;
}

/// A tile's cover, with its progress along its foot, if it's partway;
/// `title` on it while it has no art. Its marks are under it, at its name's
/// line's end (`marksView`), leaving its corners to the art, as the apps'.
function coverView(tile, title = tile.name) {
  const cover = el("div", { class: "cover" });
  if ((tile.thumb && tile.thumb !== "-") || tile.cover) {
    let placed = false;
    cover.near = () => {
      // Its placeholder at once, as the server draws it; its cover in turn.
      if (!placed && tile.thumb && tile.thumb !== "-") cover.style.backgroundImage = `url("${thumbURL(tile.thumb)}")`;
      placed = true;
      if (!tile.cover) return nearScreen.unobserve(cover);
      covers.waiting.add(cover);
      nextCovers();
    };
    cover.fetchCover = () => {
      nearScreen.unobserve(cover);
      const img = el("img", { alt: "", decoding: "async" });
      covers.loading.add(img);
      const done = () => {
        if (!covers.loading.delete(img)) return;
        nextCovers();
      };
      // Shown at once, once loaded, without a fade, over its placeholder.
      img.style.visibility = "hidden";
      img.onload = () => {
        img.style.visibility = "";
        // In a carousel, the cover's own shape, if its placeholder's differs.
        if (img.naturalHeight) cover.closest(".tile")?.style.setProperty("--shape", nearestShape(img.naturalWidth / img.naturalHeight));
        done();
      };
      img.onerror = () => { img.remove(); done(); };
      // Clearing its address cancels the request; its cover waits to load
      // again as it nears the screen, its page put back (see `kept`).
      img.stop = () => { img.removeAttribute("src"); img.remove(); done(); nearScreen.observe(cover); };
      img.src = coverURL(tile.cover);
      // Under its progress, which comes before it.
      cover.prepend(img);
    };
    nearScreen.observe(cover);
  }
  if (!tile.thumb && !tile.cover) {
    cover.append(el("div", { class: "initials" }, title));
  }
  if (!tile.watched && tile.progress > 0) cover.append(el("div", { class: "meter" }, el("span", { style: `width:${Math.round(tile.progress * 100)}%` })));
  return cover;
}

/// A tile's marks, at its name's line's end: a star if on `lists`, a check
/// if watched; nothing if neither.
function marksView(tile, lists) {
  if (!lists.length && !tile.watched) return null;
  return el("span", { class: "marks" },
    lists.length ? el("span", { class: "mark-star", title: "On " + lists.map((l) => l.name).join(", ") }, "★") : null,
    tile.watched ? watchedMark() : null);
}

/// Watched, as tiles and items' rows mark it: a check on a green circle.
const watchedMark = () => el("span", { class: "mark-watched", title: "Watched" }, "✓");

/// "Season 3", "Specials", or a dated series' season's year alone, "2026"
/// (a season of 1000 or more, as the core reads it), as the apps name them.
function seasonName(season) {
  return season === 0 ? "Specials" : season >= 1000 ? String(season) : `Season ${season}`;
}

/// A series' seasons in order, specials last, as the apps have them.
function seasonsInOrder(seasons) {
  const sorted = seasons.slice().sort((a, b) => a.season - b.season);
  return [...sorted.filter((t) => t.season !== 0), ...sorted.filter((t) => t.season === 0)];
}

/// What a series' seasons (in order) come to, as the Mac's tile says it:
/// "3 seasons"; a dated series' years, "2024–2026"; of one season but the
/// first, its name; nothing for a first alone (a miniseries, or one cut
/// short).
function seasonsCaption(seasons) {
  const numbered = seasons.map((t) => t.season).filter((s) => s !== 0);
  if (numbered.length && numbered[0] >= 1000) {
    const first = numbered[0], last = numbered.at(-1);
    return first === last ? String(first) : `${first}–${last}`;
  }
  if (seasons.length !== 1) return `${seasons.length} seasons`;
  return seasons[0].season === 1 ? "" : seasonName(seasons[0].season);
}

/// Whether the Series shelf shows a tile per series, opening its seasons in
/// place (Group by Series, as this browser last chose, on at first), else
/// every season under its series' name.
function groupsSeries() {
  return localStorage.getItem("groupsSeries") !== "false";
}

/// A series' tile, standing for it: its first season's cover, marked as
/// the whole series is (on a list if any season is, watched if every one
/// is, else its progress over them all); its name, and under it what its
/// seasons come to, with its year, if its name has one, at that line's end
/// (or, where that line's blank, beside its name if there's room). One of
/// a single season is that season's tile, opening its page; others open
/// their seasons in place, on a band below their row.
function seriesTileView(s) {
  const seasons = s.seasons;
  const elapsed = seasons.reduce((n, t) => n + (t.elapsed || 0), 0);
  const runtime = seasons.reduce((n, t) => n + (t.runtime || 0), 0);
  const whole = { ...seasons[0], watched: seasons.every((t) => t.watched), progress: runtime ? elapsed / runtime : 0 };
  const lists = library.mine.filter((l) => seasons.some((t) => l.titles.has(listKey(t))));
  const caption = seasonsCaption(seasons);
  const year = s.year ? el("span", { class: "year" }, String(s.year)) : null;
  const marks = marksView(whole, lists);
  const label = caption
    ? [el("div", { class: "name-row" }, el("span", { class: "name" }, s.name), marks), el("div", { class: "sub split" }, el("span", {}, caption), year)]
    : [el("div", { class: "name-year" }, el("span", { class: "name-row" }, el("span", { class: "name" }, s.name), marks), year)];
  const single = seasons.length === 1;
  const unavailable = seasons.every((t) => t.unavailable) ? " unavailable" : "";
  const a = el("a", { class: `tile season series-tile${unavailable}`, ...(single ? { href: "#title/" + encodeURIComponent(s.key) + "/" + seasons[0].season }
    : { href: "#series", role: "button", "aria-expanded": "false", "data-series": s.key }) }, coverView(whole), ...label);
  // What it was drawn from, to draw it again if that changes (see `patch`).
  a.series = s;
  a.looks = seasons.map(looks).join();
  if (!single) a.addEventListener("click", (e) => {
    e.preventDefault();
    toggleBand(a, s);
  });
  return a;
}

/// The Series shelf's open series: its tile, and its band.
let open = null;

/// Opens a series' seasons on a band below its tile's row, its point under
/// the tile, closing any other; or, open, closes it. `instantly`, as a
/// shelf comes back as it was left, without growing.
function toggleBand(tile, s, instantly = false) {
  const was = open?.tile === tile;
  closeBand();
  if (was) return;
  const band = el("div", { class: "band" }, el("div", { class: "band-inner" },
    el("div", { class: "grid" }, s.seasons.map((t) => tileView(t, true)))));
  open = { tile, band, key: s.key };
  tile.setAttribute("aria-expanded", "true");
  if (instantly) band.classList.add("open");
  placeBand();
  // Grown from nothing, pushing the rows after it down, and faded in.
  if (!instantly) requestAnimationFrame(() => band.classList.add("open"));
}

/// Closes the open series' band, shrinking it as the rows after it rise.
function closeBand() {
  if (!open) return;
  const { tile, band } = open;
  open = null;
  tile.setAttribute("aria-expanded", "false");
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return band.remove();
  band.addEventListener("transitionend", () => band.remove(), { once: true });
  band.classList.remove("open");
}

/// Puts the open band after the last tile of its series' row, as many as
/// the grid's columns, and its point under the series; again as the window
/// changes and the columns with it.
function placeBand() {
  if (!open) return;
  const { tile, band } = open;
  const grid = tile.parentElement;
  const columns = getComputedStyle(grid).gridTemplateColumns.split(" ").length;
  const tiles = [...grid.children].filter((c) => !c.classList.contains("band"));
  const i = tiles.indexOf(tile);
  tiles[Math.min(tiles.length - 1, Math.floor(i / columns) * columns + columns - 1)].after(band);
  const at = tile.getBoundingClientRect();
  band.style.setProperty("--notch", `${at.left - grid.getBoundingClientRect().left + at.width / 2}px`);
}
addEventListener("resize", placeBand);

/// The Series shelf's tile per series, in the order their seasons come,
/// each with all its seasons (not only those a search matched).
function seriesTiles(tiles) {
  const series = [];
  const seen = new Set();
  for (const t of tiles) {
    if (seen.has(t.key)) continue;
    seen.add(t.key);
    series.push({ key: t.key, name: t.name, year: t.year, seasons: seasonsInOrder(library.tiles.filter((s) => s.key === t.key)) });
  }
  return fill(el("div", { class: "grid" }), series, seriesTileView);
}

/// What's searched for: what's typed, where search is shown (beside every
/// shelf, wide; narrow, on its own tab).
function query() {
  return wide.matches || shownShelf === "search" ? search.value.trim() : "";
}

/// Tiles matching the search, by name.
function matching(tiles) {
  const words = query().toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return tiles;
  return tiles.filter((t) => words.every((w) => t.name.toLowerCase().includes(w)));
}

/// What a shelf is sorted by (`title`, `released`, `added`, or `watched`),
/// and whether the other way round, as this browser last chose, else what's
/// being watched the latest first, and the rest by title, as the apps do.
function orderOf(shelf) {
  const all = orders();
  // Watching was In Progress.
  const chosen = all[shelf] || (shelf === "watching" ? all["in-progress"] : null);
  return chosen || { by: shelf === "watching" || shelf === "watched" ? "watched" : "title", reversed: false };
}

function chooseOrder(shelf, order) {
  localStorage.setItem("orders", JSON.stringify({ ...orders(), [shelf]: order }));
}

/// Each shelf's order, as this browser chose it.
function orders() {
  return JSON.parse(localStorage.getItem("orders") || "{}");
}

/// Tiles in an order, as the core places them (each place counting from
/// what comes first in the order's usual direction: A to Z, the newest),
/// a series' seasons together; those with no place in it last, by title.
function ordered(tiles, order) {
  return tiles.slice().sort((a, b) => {
    const x = a.order[order.by];
    const y = b.order[order.by];
    if (x != null && y != null && x !== y) return order.reversed ? y - x : x - y;
    if ((x == null) !== (y == null)) return x == null ? 1 : -1;
    return a.order.title - b.order.title || (a.season || 0) - (b.season || 0);
  });
}

/// Which showing of a page is the latest, so building an older one stops.
let showing = 0;

/// Appends what `make` makes of each of `items` to `parent`: a screenful at
/// once, the rest a slice a frame, so a shelf of thousands shows at once and
/// the page never stops answering.
function fill(parent, items, make) {
  // A trial run (`makeup`) notes what it would show, drawing none of it.
  if (trial) {
    parent.trialItems = items;
    return parent;
  }
  const mine = showing;
  let i = 0;
  parent.dataset.filling = "";
  const slice = (n) => {
    if (mine !== showing) return;
    for (const end = Math.min(items.length, i + n); i < end; i++) parent.append(make(items[i]));
    if (i < items.length) requestAnimationFrame(() => slice(400));
    else delete parent.dataset.filling;
  };
  slice(80);
  return parent;
}

/// Whether a shelf's being built only to see what it would show.
let trial = false;

/// What a shelf shows, as it would be built now: its headings and text,
/// and its tiles' identities, in order (a trial run, drawing no tiles); the
/// same, a page of it kept can be put back.
function makeup(shelf) {
  trial = true;
  try {
    return JSON.stringify(shelves[shelf]().map((p) => p.trialItems ? p.trialItems.map(idOf) : p.textContent));
  } finally {
    trial = false;
  }
}

/// The shelf left, kept as it was (its page, where it was scrolled, and the
/// series open), to put back as it's shown again, rather than build it anew,
/// if it would show the same tiles in the same order; else it's built anew
/// and put back where it was (see `places`).
let kept = null;
/// The makeup of the shelf shown, kept with its page.
let shownMakeup = null;

/// Draws again the tiles of a page put back whose data changed meanwhile
/// (watched, played, put on a list, a cover found), as only they need.
function patch() {
  const byId = new Map(library.tiles.map((t) => [idOf(t), t]));
  for (const a of main.querySelectorAll("a.tile")) {
    let fresh;
    if (a.series) {
      const seasons = seasonsInOrder(library.tiles.filter((t) => t.key === a.series.key));
      if (seasons.map(looks).join() === a.looks) continue;
      fresh = seriesTileView({ ...a.series, seasons });
      if (open?.tile === a) {
        open.tile = fresh;
        fresh.setAttribute("aria-expanded", "true");
      }
    } else {
      const t = byId.get(a.tileId);
      if (!t || looks(t) === a.looks) continue;
      fresh = tileView(t, a.underSeries);
    }
    a.replaceWith(fresh);
  }
}

function grid(tiles) {
  return fill(el("div", { class: "grid" }), tiles, (t) => tileView(t));
}

/// Seasons under their series' names, as the Mac's grid has them.
function seriesGrid(tiles) {
  const series = [];
  for (const t of tiles) {
    if (series.at(-1)?.key !== t.key) series.push({ key: t.key, name: t.name, year: t.year, seasons: [] });
    series.at(-1).seasons.push(t);
  }
  return [fill(el("div"), series, (s) => {
    const part = document.createDocumentFragment();
    part.append(el("div", { class: "series-name" }, s.name + (s.year ? ` (${s.year})` : "")),
      el("div", { class: "grid" }, s.seasons.map((t) => tileView(t, true))));
    return part;
  })];
}

/// A shelf's tiles as the Mac's grid lays them out: its movies first, then
/// each series' seasons under its name, so each shape has rows of its own.
function shelfGrid(tiles) {
  const movies = tiles.filter((t) => t.kind === "movie");
  const seasons = tiles.filter((t) => t.kind === "series");
  return [movies.length ? grid(movies) : null, ...(seasons.length ? seriesGrid(seasons) : [])].filter(Boolean);
}

/// A row of tiles under its name, scrolling sideways, its See All (how many
/// it holds) going to its whole shelf, as iOS's rows have it.
function carousel(name, tiles, href) {
  const titles = new Set(tiles.map((t) => t.key)).size;
  return [el("div", { class: "row-heading" }, el("h2", {}, name),
    el("a", { class: "see-all", href }, `See All ${titles.toLocaleString()} ›`)),
  fill(el("div", { class: "carousel" }, []), tiles, (t) => tileView(t))];
}

/// A list's row, if anything on it matches; else, with `always`, its
/// heading, saying so.
function listRow(l, always = false) {
  const on = onList(l);
  if (on.length) return carousel(listLabel(l), ordered(on, orderOf(`lists/${l.id}`)), `#lists/${l.id}`);
  return !always ? [] : [el("div", { class: "row-heading" }, el("h2", {}, listLabel(l)), el("a", { class: "see-all", href: `#lists/${l.id}` }, "See All ›")),
    el("p", { class: "dim" }, query() ? "Nothing on it matches." : "Nothing on it yet.")];
}

/// A list's titles, and its placeholders, matching the search.
function onList(l) {
  return matching([...library.tiles.filter((t) => l.titles.has(listKey(t))), ...placeholders(l)]);
}

/// A shelf's tiles (`onShelf`'s), matching the search, in its order.
function onShelfOrdered(shelf) {
  return ordered(matching(library.tiles.filter(onShelf[shelf])), orderOf(shelf));
}

const shelves = {
  // The tab bar's: Continue Watching, then a row per list, as the Apple
  // TV's home page has them; the shelves they don't show first.
  home: () => {
    const going = matching(library.tiles.filter(onShelf.watching));
    const parts = [el("nav", { class: "shelf-links", "aria-label": "More shelves" },
      el("a", { href: "#watched" }, "Watched"), downloads.enabled ? el("a", { href: "#kept" }, "Kept") : null)];
    if (going.length) parts.push(...carousel("Continue Watching", ordered(going, { by: "watched" }), "#watching"));
    for (const l of library.lists) parts.push(...listRow(l));
    return parts.length > 1 ? parts : [...parts, empty("Nothing in progress or on your lists yet.")];
  },
  movies: () => {
    const t = onShelfOrdered("movies");
    return t.length ? [grid(t)] : [empty("No movies.")];
  },
  series: () => {
    const t = onShelfOrdered("series");
    if (!t.length) return [empty("No series.")];
    return groupsSeries() ? [seriesTiles(t)] : seriesGrid(t);
  },
  // Every list as a row, its See All going to its page, then a new one.
  lists: () => {
    const parts = [el("div", { class: "new-list" }, el("button", { type: "button", title: "New list", onclick: showNewList }, "⊕ New List"))];
    for (const l of library.lists) parts.push(...listRow(l, true));
    if (!library.lists.length) parts.push(empty("Make a list to keep titles in, as a watchlist or favorites."));
    return parts;
  },
  // A list's page, with what's done to it, if it's this person's.
  list: () => {
    const l = shownList;
    if (!l) return [empty("That list is gone.")];
    const t = ordered(onList(l), orderOf(`lists/${l.id}`));
    // Another member's: theirs to change, so only its name.
    const heading = l.mine ? el("div", { class: "list-heading" },
      el("h2", {}, listLabel(l)),
      el("button", { class: "mark", type: "button", title: "Add a missing title", "aria-label": `Add a title not in the library to ${l.name}`, onclick: () => askWanted([l]) }, "＋"),
      el("button", { class: "mark", type: "button", title: "Rename list", "aria-label": `Rename ${l.name}`, onclick: () => renameList(l) }, "✎"),
      el("button", { class: "mark", type: "button", "aria-pressed": isShared(l), title: isShared(l) ? "Shared with everyone in the library" : "Share with everyone in the library", "aria-label": isShared(l) ? `Stop sharing ${l.name}` : `Share ${l.name}`, onclick: () => shareList(l) }, isShared(l) ? "Shared" : "Share"),
      el("button", { class: "mark", type: "button", title: "Delete list", "aria-label": `Delete ${l.name}`, onclick: () => deleteList(l) }, "✕"))
      : el("div", { class: "list-heading" }, el("h2", {}, listLabel(l)));
    return [heading, ...(t.length ? shelfGrid(t) : [el("p", { class: "dim" }, query() ? "Nothing on it matches." : l.mine ? "Nothing on it yet: add titles from their pages." : "Nothing on it yet.")])];
  },
  // Played, split in two, as the Mac's sidebar has it.
  watching: () => {
    const t = onShelfOrdered("watching");
    return t.length ? shelfGrid(t) : [empty("What you're watching shows here.")];
  },
  // The tab bar's: movies, then a tile per series, as the Apple TV's.
  search: () => {
    if (!query()) return [empty("Search for a movie or series by name.")];
    const t = onShelfOrdered("search");
    if (!t.length) return [empty("Nothing matches.")];
    const movies = t.filter((x) => x.kind === "movie");
    const series = t.filter((x) => x.kind === "series");
    if (!movies.length || !series.length) return [movies.length ? grid(movies) : seriesTiles(series)];
    return [el("h2", {}, "Movies"), grid(movies), el("h2", {}, "Series"), seriesTiles(series)];
  },
  watched: () => {
    const t = onShelfOrdered("watched");
    return t.length ? shelfGrid(t) : [empty("What you've watched shows here.")];
  },
  // What the server keeps, as the Mac's Downloaded shelf has what it does.
  kept: () => {
    const t = onShelfOrdered("kept");
    return t.length ? shelfGrid(t) : [empty("What you keep on the server shows here.")];
  },
};

function empty(text) { return el("p", { class: "empty" }, text); }

// Lists.

/// Asks for a title not in the library yet, to put on a list by name: a
/// movie, or a series' season, with its year as its file will be named (so
/// it's matched as it comes), and a note, as an article's address. Given a
/// placeholder's tile (`editing`), changes it instead, on each of `lists`.
function askWanted(lists, editing = null) {
  const dialog = document.getElementById("want");
  const form = dialog.querySelector("form");
  form.reset();
  const f = form.elements;
  dialog.querySelector("h2").textContent = editing ? `Edit ${editing.name}` : `Add a missing title to ${lists[0].name}`;
  form.querySelector("[type=submit]").textContent = editing ? "Save" : "Add";
  if (editing) {
    f.kind.value = editing.kind;
    f.name.value = editing.name;
    f.year.value = editing.year ?? "";
    f.season.value = editing.season ?? 1;
    f.note.value = editing.wanted || "";
  }
  const seasonRow = form.querySelector(".season");
  const kind = () => f.kind.value;
  seasonRow.hidden = kind() !== "series";
  form.onchange = () => { seasonRow.hidden = kind() !== "series"; };
  form.onsubmit = async (e) => {
    e.preventDefault();
    const want = { kind: kind(), name: f.name.value.trim(), note: f.note.value.trim() };
    if (f.year.value) want.year = Number(f.year.value);
    if (want.kind === "series") want.season = Number(f.season.value || 1);
    try {
      for (const l of lists) await api(editing ? "list-want-edit" : "list-want", editing ? { list: l.id, key: editing.wantedKey, want } : { list: l.id, want });
      dialog.close();
      await refresh();
    } catch (err) {
      problem(err.message);
    }
  };
  dialog.showModal();
}

/// The list whose page is shown (`#lists/<id>`).
let shownList = null;

/// The sidebar's ⊕, at the Lists heading's right: a new list, shown.
document.getElementById("new-list").addEventListener("click", showNewList);

/// This person's lists a tile's key is on.
function listsOf(key) { return library.mine.filter((l) => l.titles.has(key)); }

/// A list's name as shown: another member's, as theirs, if they're named.
function listName(l) {
  return !l.mine && l.ownerName ? `${l.ownerName}’s ${l.name}` : l.name;
}

/// Whether every member sees a list (its `mode`), not its owner alone.
function isShared(l) { return l.mode === "shared"; }

/// A list's name with, if it's shared (this person's or another's), a mark
/// of two people before it, in the text's own color.
function listLabel(l) {
  if (!isShared(l)) return listName(l);
  const mark = el("span", { class: "shared-mark", role: "img", "aria-label": "Shared", title: "Shared with everyone in the library" });
  mark.innerHTML = '<svg viewBox="0 0 20 16" fill="currentColor" aria-hidden="true"><circle cx="7" cy="4.5" r="3.2"/><path d="M0.5 15.5c0-3.6 2.9-6 6.5-6s6.5 2.4 6.5 6z"/><circle cx="14.5" cy="5.5" r="2.6" opacity=".55"/><path d="M13.2 10.1c.4-.1.9-.1 1.3-.1 2.9 0 5 2 5 5.5h-4.6c0-2.2-.6-4-1.7-5.4z" opacity=".55"/></svg>';
  return [mark, listName(l)];
}

/// Makes a new list, as asked, and shows it.
async function showNewList() {
  const id = await newList();
  if (id) location.hash = `#lists/${id}`;
}

/// Asks for a new list's name, and makes it, returning its ID.
async function newList() {
  const name = prompt("New list’s name:", "")?.trim();
  if (!name) return null;
  const id = await api("list-create", { name });
  await refresh();
  return id;
}

async function renameList(l) {
  const name = prompt(`Rename “${l.name}” to:`, l.name)?.trim();
  if (!name || name === l.name) return;
  await api("list-rename", { id: l.id, name });
  await refresh();
}

/// Shares a list with everyone in the library, confirmed first, as their
/// devices keep what they receive; or makes it this person's alone again.
async function shareList(l) {
  if (!isShared(l) && !confirm(`Share “${l.name}” with everyone in the library? They’ll see its titles, and only you can change it. If you stop sharing it, their devices keep what they’ve already received.`)) return;
  await api("list-share", { id: l.id, on: !isShared(l) });
  await refresh();
}

async function deleteList(l) {
  if (!confirm(`Delete the list “${l.name}”? Its titles stay in the library. This can’t be undone.`)) return;
  await api("list-remove", { id: l.id });
  await reload();
  // Its own page goes with it, to all of them.
  if (shownList?.id === l.id) location.hash = "#lists";
  else route();
}

/// A title page's Lists button: a menu of every list, each checked if the
/// title's on it, pressed to put it on or take it off; then New List…,
/// which puts it on the new one.
function listsMenu(key) {
  const on = listsOf(key);
  const menu = el("div", { class: "menu", popover: "auto", id: "lists-menu", role: "menu", "aria-label": "Lists" },
    ...library.mine.map((l) => el("button", { type: "button", role: "menuitemcheckbox", "aria-checked": l.titles.has(key), onclick: async () => {
      await api("listed", { list: l.id, key, on: !l.titles.has(key) });
      await refresh();
    } }, (l.titles.has(key) ? "✓ " : "\u2003") + l.name)),
    el("button", { type: "button", role: "menuitem", onclick: async () => {
      const id = await newList();
      if (id) { await api("listed", { list: id, key, on: true }); await refresh(); }
    } }, "\u2003New List…"));
  // The same name whatever it's on, so nothing beside it moves; its
  // chevron says it opens a menu, as a pull-down button's does.
  const button = el("button", { class: on.length ? "mark on" : "mark", type: "button", popovertarget: "lists-menu", "aria-haspopup": "menu", "aria-expanded": "false", title: on.length ? "On " + on.map((l) => l.name).join(", ") : "Lists" },
    on.length ? el("span", { class: "mark-star" }, "★") : "☆", " Lists", el("span", { class: "chevron", "aria-hidden": "true" }, "▾"));
  menu.addEventListener("toggle", (e) => button.setAttribute("aria-expanded", String(e.newState === "open")));
  return [button, menu];
}

/// Each shelf's tiles, before a search.
const onShelf = {
  home: (t) => (t.started && !t.watched) || library.listed.has(listKey(t)),
  movies: (t) => t.kind === "movie",
  series: (t) => t.kind === "series",
  lists: (t) => library.shown.has(listKey(t)),
  list: (t) => !!shownList?.titles.has(listKey(t)),
  watching: (t) => t.started && !t.watched,
  search: () => true,
  watched: (t) => t.watched,
  kept: (t) => heldTile(t),
};

/// How many a shelf holds, for the status line, as the Mac's says it:
/// "4,000 movies", "300 series, 1,200 seasons, 15,000 episodes", or with a
/// search, "12 of 4,000 movies match “zoo”".
function counts(shelf) {
  const all = library.tiles.filter(onShelf[shelf] || onShelf.home);
  const titles = new Set(all.map((t) => t.key)).size;
  const noun = shelf === "movies" ? (titles === 1 ? "movie" : "movies") : shelf === "series" ? "series" : titles === 1 ? "title" : "titles";
  const n = (x) => x.toLocaleString();
  if (query()) {
    const found = new Set(matching(all).map((t) => t.key)).size;
    return `${n(found)} of ${n(titles)} ${noun} match “${query()}”`;
  }
  if (shelf === "series") {
    const episodes = all.reduce((sum, t) => sum + t.items, 0);
    return `${n(titles)} series, ${n(all.length)} ${all.length === 1 ? "season" : "seasons"}, ${n(episodes)} ${episodes === 1 ? "episode" : "episodes"}`;
  }
  return `${n(titles)} ${noun}`;
}

// Title pages.

// Items come named by the core (`season`, `number`, `label`, `name`), so
// no key is read here.

function itemsOf(detail, season) {
  if (season == null) return detail.items;
  // In the core's order.
  return detail.items.filter((i) => i.season === season);
}

/// Whether a browser plays a copy's file: MP4, M4V, or MOV (not MKV or ISO).
function playable(url) {
  return /\.(mp4|m4v|mov)$/i.test(new URL(url, location.href).pathname);
}

const hevc = document.createElement("video").canPlayType('video/mp4; codecs="hvc1.1.6.L93.B0"') !== "";

/// A quality's rank: higher resolution first (as the core gives it), among
/// those this browser plays (HEVC only where it's supported).
function rank(q) {
  if (!hevc && /\b(hevc|x265|h265)\b/i.test(q.label)) return -1;
  return q.height ?? 1;
}

/// The qualities of these items whose copies this browser plays, best first.
function qualitiesOf(items) {
  const found = new Map();
  for (const item of items) for (const q of item.qualities) {
    if (!q.copies.some((c) => c.url && playable(c.url))) continue;
    if (rank(q) < 0) continue;
    if (!found.has(q.label)) found.set(q.label, q);
  }
  return [...found.values()].sort((a, b) => rank(b) - rank(a));
}

/// Each quality's short label, as the core names it ("1080p", "4K HDR",
/// "720p Very Fast").
function shortNames(qualities) {
  return new Map(qualities.map((q) => [q.label, q.short]));
}

/// The quality chosen on this page, kept per title while the page is open.
const chosenQuality = new Map();

/// A running time, from milliseconds (as `duration` fields give it).
function formatTime(ms) {
  const minutes = Math.max(1, Math.round(ms / 60000));
  return minutes >= 60 ? `${Math.floor(minutes / 60)}h ${minutes % 60}m` : `${minutes}m`;
}

/// An episode's name in a list; a version's, with the title's.
function itemTitle(detail, item) {
  if (item.season != null) return item.name;
  return item.label === "Standard" ? detail.name : `${detail.name} (${item.label})`;
}

/// What Play plays, as the core marks it.
function nextIndex(items) {
  return Math.max(0, items.findIndex((i) => i.next));
}

async function titlePage(key, season) {
  const detail = await api("title?" + new URLSearchParams({ key }));
  const seasons = detail.seasons;
  const isSeries = seasons.length > 0;
  if (isSeries && season == null) season = seasons.find((s) => itemsOf(detail, s).some((i) => !i.watched)) ?? seasons[0];
  const items = itemsOf(detail, isSeries ? season : null);
  const qualities = qualitiesOf(items);
  const quality = qualities.find((q) => q.label === chosenQuality.get(key))?.label ?? qualities[0]?.label;
  const tile = library.tiles.find((t) => t.key === key && (t.season ?? null) === (isSeries ? season : null))
    || library.tiles.find((t) => t.key === key);
  const artCover = detail.covers[isSeries ? `art:s${String(season).padStart(2, "0")}` : "art"] || detail.covers.art;
  const art = el("div", { class: `art${isSeries ? " square" : ""}` });
  if (tile?.thumb && tile.thumb !== "-") art.style.backgroundImage = `url("${thumbURL(tile.thumb)}")`;
  if (artCover) {
    // As a tile's: shown once loaded, else gone, leaving its placeholder.
    const img = el("img", { alt: "", src: coverURL(artCover) });
    img.style.visibility = "hidden";
    img.onload = () => { img.style.visibility = ""; };
    img.onerror = () => img.remove();
    art.append(img);
  }

  const next = nextIndex(items);
  const resuming = items[next] && items[next].position > 0 && !items[next].watched;
  const allWatched = items.length > 0 && items.every((i) => i.watched);
  const nextLabel = !items[next] ? "Play" : isSeries
    ? `${resuming ? "Resume" : "Play"} ${items[next].label}`
    : resuming ? "Resume" : "Play";

  const play = (index, fromStart) => playQueue(detail, items, index, quality, fromStart);
  // Playing, on a row of its own, filled, Start Over before Resume, as a
  // player's timeline starts at its leading edge: the marks, quieter,
  // beside it, as the Mac's inspector has them.
  const actions = el("div", { class: "actions" },
    resuming ? el("button", { type: "button", disabled: !quality, onclick: () => play(next, true) }, "⏮ Start Over") : null,
    el("button", { class: "primary", type: "button", disabled: !quality, onclick: () => play(next) }, "▶ " + nextLabel),
    ...listsMenu(isSeries ? `${key}#${season}` : key),
    el("button", { class: "mark", type: "button", "aria-pressed": allWatched, onclick: async () => {
      for (const i of items) await api("watched", { item: `${key}/${i.key}`, watched: !allWatched });
      await refresh();
    } }, allWatched ? [watchedMark(), " Watched"] : "○ Unwatched"),
  );
  if (!quality) problem("None of its copies plays in a browser (MKV and ISO files don't).");

  // The quality, by its short label, with its full name as its sources
  // give it, in a row of its own above Play, as the Mac's inspector has
  // it, so choosing it changes only what's below; a title of one quality
  // says it as text, so every title says what it plays in.
  const short = shortNames(qualities);
  const chosen = qualities.find((q) => q.label === quality);
  const qualityRow = !chosen ? null : el("div", { class: "quality" }, el("span", { class: "label" }, "Quality"),
    qualities.length > 1 ? el("select", {
      "aria-label": "Quality",
      title: chosen.name,
      onchange: (e) => { chosenQuality.set(key, e.target.value); route(); },
    }, qualities.map((q) => el("option", { value: q.label, selected: q.label === quality, title: q.name }, short.get(q.label))))
      : el("span", { title: chosen.name }, short.get(chosen.label)));

  // The season, unless its pop-up says which.
  const facts = [isSeries && seasons.length < 2 ? seasonName(season) : null, detail.year, detail.fields.genre, detail.fields.network,
    !isSeries && items[0]?.fields.duration ? formatTime(Number(items[0].fields.duration)) : null].filter(Boolean).join(" · ");
  const sizes = await keepSizes(detail, items, isSeries ? season : null, quality);
  const body = [
    el("h1", {}, detail.name),
    facts ? el("div", { class: "facts" }, facts) : null,
    qualityRow,
    actions,
    keepRow(detail, items, isSeries ? season : null, quality, sizes),
    !isSeries && items.length === 1 ? progressRow(detail, items[0]) : null,
    detail.fields.description && !isSeries ? el("p", { class: "description" }, detail.fields.description) : null,
  ];
  if (isSeries) {
    // Which season, in the heading of the episodes it chooses.
    const seasonPicker = seasons.length > 1 ? el("select", {
      "aria-label": "Season",
      onchange: (e) => { location.hash = `#title/${encodeURIComponent(key)}/${e.target.value}`; },
    }, seasons.map((s) => el("option", { value: s, selected: s === season }, seasonName(s)))) : null;
    body.push(el("div", { class: "heading" }, el("h2", {}, "Episodes"), seasonPicker));
  } else if (items.length > 1) {
    body.push(el("div", { class: "heading" }, el("h2", {}, "Versions")));
  }
  // An episode with its length, progress, and description; a version, its name.
  if (isSeries || items.length > 1) body.push(el("ul", { class: "episodes" }, items.map((item, n) => el("li", {},
    el("button", { class: "play", type: "button", "aria-label": "Play", disabled: !quality, onclick: () => play(n) }, "▶"),
    el("span", { class: "title" }, itemTitle(detail, item)),
    el("span", { class: "time" }, item.watched ? watchedMark() : null, isSeries && item.fields.duration ? formatTime(Number(item.fields.duration)) : ""),
    itemControls(detail, [item], quality),
    isSeries ? progressRow(detail, item) : null,
    isSeries && item.fields.description ? el("span", { class: "desc" }, item.fields.description) : null,
  ))));
  describe(detail, items);
  return [el("div", { class: "page" }, art, el("div", {}, body))];
}

/// An item's progress, if it's partway: a meter, and what's left.
function progressRow(detail, item) {
  if (!(item.position > 0 && item.duration > 0 && !item.watched)) return null;
  return el("div", { class: "progress" },
    el("progress", { max: item.duration, value: item.position }),
    el("span", { class: "left" }, `${formatTime(item.duration - item.position)} left`));
}

/// Items asked to be described, so each is asked once a page load.
const described = new Set();

/// Reads the episodes shown that weren't described from their files as they
/// are now (a crawl reads only a season's first; a file retagged since reads
/// again): their titles and descriptions, one at a time, then shows the page
/// again.
async function describe(detail, items) {
  const page = location.hash;
  let any = false;
  for (const item of items) {
    const key = `${detail.key}/${item.key}`;
    if (item.season == null || item.described || described.has(key)) continue;
    described.add(key);
    if (location.hash !== page || session) return;
    await api("describe", { item: key }).then(() => { any = true; }).catch(() => {});
  }
  if (any && location.hash === page && !session) route();
}

// Downloading a file to this computer, through the server, which reaches
// sources this browser may not; and keeping one on the server (its
// downloads, with `serve --downloads`, as the Mac keeps its own), named
// only in passing, as the computer in hand is what a person minds.

/// What the server last said of what it keeps (its downloads).
let downloads = { enabled: false };
/// The shelf's counts, for the status line once nothing's being kept.
let shelfStatus = "";
/// Controls showing what's kept, updated in place as it changes.
const watching = new Set();

function noteDownloads(kept) {
  downloads = kept.enabled ? { enabled: true, device: kept.device, ...kept.report } : { enabled: false };
  document.querySelector('#sidebar a[data-shelf="kept"]').hidden = !downloads.enabled;
  for (const update of watching) update();
  if (!problemShown) show(keepingLine() || shelfStatus);
  pollDownloads();
}

/// Asks again every 2 seconds while anything's coming or waits to.
let polling = null;
function pollDownloads() {
  clearTimeout(polling);
  if (!downloads.enabled || !(downloads.running || pending())) return;
  polling = setTimeout(async () => {
    try { noteDownloads(await api("downloads")); } catch { pollDownloads(); }
  }, 2000);
}

/// Whether anything wanted (by hand, or a series' next) isn't held yet.
function pending() {
  const held = new Set(downloads.held.map((h) => h.item));
  return downloads.ahead.some((k) => !held.has(k)) || downloads.wanted.some((w) => !held.has(w.key));
}

/// "Keeping on the server… 120 of 900 MB", while it comes.
function keepingLine() {
  if (!downloads.enabled || !downloads.running || !downloads.total_mb) return "";
  return `Keeping on the server… ${downloads.done_mb.toLocaleString()} of ${downloads.total_mb.toLocaleString()} MB`;
}

/// Where it stands for these items (full keys): held, coming (with how
/// far, if under way), or neither.
function stateOf(keys) {
  if (!downloads.enabled || !keys.length) return {};
  const held = keys.map((k) => downloads.held.find((h) => h.item === k));
  if (held.every(Boolean)) return { held: true, only: held.some((h) => h.only), size: held.reduce((s, h) => s + h.size, 0) };
  const fetching = downloads.fetching && keys.includes(downloads.fetching.item) ? downloads.fetching : null;
  const wanted = keys.some((k) => downloads.wanted.some((w) => w.key === k) || downloads.ahead.includes(k));
  return { coming: wanted || !!fetching, fetching };
}

/// Whether a tile has anything held: a movie's, or a season's episodes.
function heldTile(tile) {
  if (!downloads.enabled) return false;
  const season = tile.season == null ? null : String(tile.season).padStart(2, "0");
  return downloads.held.some((h) => {
    if (!h.item.startsWith(tile.key + "/")) return false;
    if (season == null) return true;
    const rest = h.item.slice(tile.key.length);
    return rest.startsWith(`/e/s${season}e`) || rest.startsWith(`/e/s${season}-`);
  });
}

function bytes(n) {
  return n >= 1e9 ? `${(n / 1e9).toFixed(1)} GB` : `${Math.max(1, Math.round(n / 1e6))} MB`;
}

/// What keeping may take: free space, less what the server keeps free.
function available() { return downloads.free == null ? null : Math.max(0, downloads.free - downloads.floor); }

function sizeNote(size) {
  const room = available();
  const fits = room == null || size.needed <= room;
  return { text: bytes(size.size), fits, title: room == null ? "" : `${fits ? "" : "Won't fit: "}${bytes(room)} available on ${downloads.device}` };
}

/// What a movie's Keep keeps, as the Mac's Download downloads: the version
/// Play plays (of parts, all of them).
function keepTarget(detail, items) {
  const item = items.find((i) => i.next) || items[0];
  if (!item) return null;
  const part = item.key.indexOf("/p/");
  if (part >= 0) {
    const version = item.key.slice(0, part);
    if (!items.some((i) => i.key === version)) {
      return { key: `${detail.key}/${version}`, items: items.filter((i) => i.key.startsWith(version + "/p/")) };
    }
  }
  return { key: `${detail.key}/${item.key}`, items: [item] };
}

/// What keeping would come to, fetched before the page is drawn, so no
/// size arrives to move what's beside it: a movie's (what its Keep keeps,
/// in `quality`), or a season's choices of episodes.
async function keepSizes(detail, items, season, quality) {
  if (!downloads.enabled) return null;
  if (season == null) {
    const target = keepTarget(detail, items);
    return target ? api("download-sizes?" + new URLSearchParams({ key: target.key, quality: quality ?? "" })).catch(() => null) : null;
  }
  return api("download-sizes?" + new URLSearchParams({ key: detail.key, choices: JSON.stringify(seasonChoices.slice(1).map((c) => c[0])) })).catch(() => null);
}

/// A title page's: for a movie of one file, Download, to this computer;
/// and keeping it on the server (a movie's Keep, or a season's choice of
/// episodes, as the Mac's Download has them).
function keepRow(detail, items, season, quality, sizes) {
  const parts = [];
  const target = season == null ? keepTarget(detail, items) : null;
  if (target && target.items.length === 1) parts.push(downloadButton(target.items[0], quality));
  if (downloads.enabled) {
    if (season != null) parts.push(seasonChoice(detail, sizes));
    else if (target) parts.push(keepControls(target.items.map((i) => `${detail.key}/${i.key}`), target.key, quality, sizes?.[0]));
  }
  return parts.length ? el("div", { class: "downloads" }, parts) : null;
}

/// Keeping on the server, one button taking each turn in place, as the
/// Mac's download rows hold theirs (nothing appears or disappears), with
/// its size throughout: Keep; then, while the file comes, Keeping (a round
/// gauge in its slot, turning while it waits its turn), which under the
/// pointer is Cancel; then Kept, tinted, with a check, which under the
/// pointer is Delete. Every label is stacked in its place, so it's as wide as the
/// widest. Deleting the only copy is asked first; so is any, on a screen
/// without a pointer to show Delete first. Smaller in an episode's row.
function keepControls(keys, key, quality, size, small = false) {
  const note = size && sizeNote(size);
  const slot = el("span", { class: "slot", "aria-hidden": "true" });
  // Its size in every turn, as it's always the same file.
  const sized = (word) => note ? `${word} · ${note.text}` : word;
  const labels = el("span", { class: "labels" },
    el("span", { class: "idle" }, sized("Keep")),
    el("span", { class: "coming" }, sized("Keeping")),
    el("span", { class: "cancel" }, sized("Cancel")),
    el("span", { class: "kept" }, sized("Kept")),
    el("span", { class: "delete" }, sized("Delete")));
  let state = {};
  const button = el("button", { type: "button", class: small ? "keep small" : "keep", onclick: () => {
    if (state.held) {
      const ask = state.only ? "The server holds the only copy. Delete it anyway? It can't be had again."
        : !hovers ? `Delete it from ${downloads.device}?` : null;
      if (ask && !confirm(ask)) return;
      change("download-remove", { key });
    } else if (state.coming) {
      change("download-remove", { key });
    } else {
      change("download", { key, quality: quality ?? "" });
    }
  } }, slot, labels);
  watch(button, () => {
    state = stateOf(keys);
    const f = state.fetching;
    button.dataset.state = state.held ? "kept" : state.coming ? "coming" : "idle";
    button.classList.toggle("warn", !state.held && !state.coming && !!note && !note.fits);
    slot.replaceChildren(...(state.held ? [el("span", { class: "check" }, "✓"), el("span", { class: "bin" }, "✕")]
      : state.coming ? [ring(f?.size ? f.done / f.size : null)] : []));
    button.title = state.held ? `Kept on ${downloads.device}${state.only ? " (the only copy)" : ""}; delete it`
      : f?.size ? `Coming to ${downloads.device}: ${bytes(f.done)} of ${bytes(f.size)}; cancel it`
      : state.coming ? `Waiting its turn to come to ${downloads.device}; cancel it`
      : note?.title || `Keep on ${downloads.device}`;
  });
  return button;
}

/// Whether the pointer can hover, to show Cancel and Delete before they're
/// pressed.
const hovers = matchMedia("(hover: hover)").matches;

/// A round gauge, filled to `fraction` (0 to 1), or turning, if null.
function ring(fraction) {
  const svg = (tag, attrs) => {
    const e = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
    return e;
  };
  const r = 6, round = 2 * Math.PI * r;
  const g = svg("svg", { viewBox: "0 0 16 16", class: fraction == null ? "ring turning" : "ring" });
  g.append(svg("circle", { cx: 8, cy: 8, r, class: "track" }),
    svg("circle", { cx: 8, cy: 8, r, class: "fill", "stroke-dasharray": round, "stroke-dashoffset": round * (1 - (fraction ?? 0.25)) }));
  return g;
}

/// A season's choices of episodes to keep.
const seasonChoices = [["0", "Nothing"], ["1", "Next"], ["3", "Next 3"], ["10", "Next 10"], ["all", "All"]];

/// A season's choice of episodes to keep on the server, with what each
/// would come to.
function seasonChoice(detail, sizes) {
  const current = () => downloads.next.find((n) => n.title === detail.key)?.choice ?? "0";
  const label = ([value, name]) => {
    const s = sizes?.find((x) => x.choice === value);
    if (!s) return name;
    const note = sizeNote(s);
    return `${name} · ${note.text}${note.fits ? "" : " (won't fit)"}`;
  };
  const select = el("select", { "aria-label": "Keep", title: `Episodes to keep on ${downloads.device} as you watch`,
    onchange: (e) => change("download-next", { title: detail.key, choice: e.target.value === "0" ? "" : e.target.value }) },
  seasonChoices.map((c) => el("option", { value: c[0] }, label(c))));
  const box = el("label", { class: "download" }, "Keep ", select);
  watch(box, () => { select.value = current(); });
  return box;
}

/// An episode's or version's own: Download, to this computer, and keeping
/// it on the server.
function itemControls(detail, items, quality) {
  const keys = items.map((i) => `${detail.key}/${i.key}`);
  return el("span", { class: "item-downloads" }, downloadButton(items[0], quality), downloads.enabled ? keepControls(keys, keys[0], quality, null, true) : null);
}

/// Downloading an item's file to this computer: from the chosen quality's
/// copy whose server answers first, else any other, through the server.
function downloadButton(item, quality) {
  return el("button", { type: "button", onclick: async () => {
    const q = item.qualities.find((x) => x.label === quality) || item.qualities.find((x) => x.copies.length);
    const urls = q ? q.copies.filter((c) => c.url).sort((a, b) => a.unavailable - b.unavailable).map((c) => c.url) : [];
    if (!urls.length) return problem("No source holds it now.");
    const [url] = urls.length > 1 ? await api("race", urls).catch(() => urls) : urls;
    // A link to download, not a navigation: a server's error stays in the
    // browser's downloads, not in place of this page.
    el("a", { href: "api/file?" + new URLSearchParams({ url }), download: true }).click();
  } }, "Download");
}

/// Keeps `update` called as what's kept changes, while `box` is shown.
function watch(box, update) {
  const run = () => { if (!box.isConnected && box.dataset.shown) watching.delete(run); else update(); };
  update();
  requestAnimationFrame(() => { box.dataset.shown = "1"; });
  watching.add(run);
}

/// A change to what the server keeps, then what it comes to.
async function change(name, body) {
  try {
    await api(name, body);
    noteDownloads(await api("downloads"));
  } catch (e) {
    problem(e.message);
  }
}

// Playing.

const player = document.getElementById("player");
const video = document.getElementById("video");
const curtain = document.getElementById("curtain");
const fade = 500;
/// How much before where it was left resuming starts.
const replay = 4000;
let session = null;

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

/// Takes the sound from where it is to `to` over `ms`.
function ramp(to, ms) {
  const from = video.volume;
  const steps = 24;
  let step = 0;
  clearInterval(ramp.timer);
  ramp.timer = setInterval(() => {
    step += 1;
    video.volume = Math.min(1, Math.max(0, from + (to - from) * step / steps));
    if (step >= steps) clearInterval(ramp.timer);
  }, ms / steps);
}

/// An item's copies in the order to try them: the chosen quality's, raced
/// by the server (the one whose server answers first), then the rest, as
/// the apps order them: the nearest at or below the chosen's resolution,
/// then the nearest above, those of unknown resolution last.
async function copiesOf(item, quality, chosenHeight) {
  const chosen = item.qualities.find((q) => q.label === quality);
  const near = (q) => !chosenHeight || !q.height ? [3, 0] : q.height <= chosenHeight ? [1, -q.height] : [2, q.height];
  const others = item.qualities.filter((q) => q !== chosen && rank(q) >= 0)
    .map((q, i) => [near(q), i, q]).sort((a, b) => a[0][0] - b[0][0] || a[0][1] - b[0][1] || a[1] - b[1]).map((e) => e[2]);
  const usable = (q) => q.copies.filter((c) => c.url && playable(c.url));
  const contenders = chosen ? usable(chosen).sort((a, b) => a.unavailable - b.unavailable).map((c) => c.url) : [];
  const rest = others.flatMap(usable).map((c) => c.url);
  const raced = contenders.length > 1 ? await api("race", contenders).catch(() => contenders) : contenders;
  return [...raced, ...rest];
}

/// Plays `items` from `index` on, as the apps do: fading to black while it
/// warms up, then to the picture as its sound rises.
async function playQueue(detail, items, index, quality, fromStart = false) {
  if (session) return;
  const me = (session = { detail, items, index, quality, item: null, started: false, saved: 0, leaving: false });
  // The browser's Back leaves it, as Escape does.
  history.pushState({ playing: true }, "", location.href);
  player.hidden = false;
  curtain.classList.remove("open");
  video.volume = 0;
  await start(me, fromStart);
}

async function start(me, fromStart) {
  const item = me.items[me.index];
  me.item = item;
  me.started = false;
  document.title = item.season != null ? `${me.detail.name} · ${itemTitle(me.detail, item)}` : itemTitle(me.detail, item);
  const height = me.detail.items.flatMap((i) => i.qualities).find((q) => q.label === me.quality)?.height;
  const urls = await copiesOf(item, me.quality, height);
  for (const url of urls) {
    if (session !== me) return;
    try {
      await load(url, !fromStart && !item.watched && item.position > 0 ? Math.max(0, item.position - replay) / 1000 : 0);
    } catch {
      api("lost", { url }).catch(() => {});
      continue;
    }
    await sleep(fade);
    if (session !== me) return;
    await video.play().catch(() => {});
    curtain.classList.add("open");
    ramp(1, fade);
    return;
  }
  problem("None of its copies would load: its sources may be asleep or unavailable.");
  await leave();
}

function load(url, at) {
  return new Promise((resolve, reject) => {
    // Whichever comes first ends both.
    const ends = new AbortController();
    video.addEventListener("canplay", () => { ends.abort(); resolve(); }, { signal: ends.signal });
    video.addEventListener("error", () => { ends.abort(); reject(new Error("didn't load")); }, { signal: ends.signal });
    video.src = url;
    if (at > 0) video.addEventListener("loadedmetadata", () => { video.currentTime = at; }, { once: true });
  });
}

/// Saves where it is: every 10 seconds of playing past the first 10, where
/// it's paused, and where it's left.
function save(me) {
  if (!me.started || !me.item || !isFinite(video.duration)) return;
  me.saved = video.currentTime;
  api("progress", {
    item: `${me.detail.key}/${me.item.key}`,
    position: Math.round(video.currentTime * 1000),
    duration: Math.round(video.duration * 1000),
  }).catch((e) => problem(e.message));
}

video.addEventListener("playing", () => { if (session) session.started = true; });
video.addEventListener("timeupdate", () => {
  const me = session;
  if (!me || !me.started || video.paused) return;
  if (video.currentTime >= 10 && Math.abs(video.currentTime - me.saved) >= 10) save(me);
});
video.addEventListener("pause", () => { if (session && !session.leaving && !video.ended) save(session); });
video.addEventListener("ended", async () => {
  const me = session;
  if (!me) return;
  await api("watched", { item: `${me.detail.key}/${me.item.key}`, watched: true }).catch(() => {});
  if (me.index + 1 < me.items.length) {
    me.index += 1;
    curtain.classList.remove("open");
    await sleep(fade);
    await start(me, true);
  } else {
    await leave();
  }
});

async function leave() {
  const me = session;
  if (!me || me.leaving) return;
  me.leaving = true;
  curtain.classList.remove("open");
  ramp(0, fade);
  await sleep(fade);
  video.pause();
  save(me);
  video.removeAttribute("src");
  video.load();
  player.hidden = true;
  document.title = "Cinematheque";
  session = null;
  // Left another way than by the browser's Back: its entry goes too.
  if (history.state?.playing) history.back();
  await reload().catch(() => {});
  route();
}

addEventListener("popstate", () => { if (session && !session.leaving) leave(); });
addEventListener("pagehide", () => { if (session) save(session); });

addEventListener("keydown", (e) => {
  if (!session || e.target === search) return;
  if (e.key === "Escape") { leave(); return; }
  if (e.key === " " || e.key === "k") { video.paused ? video.play() : video.pause(); }
  else if (e.key === "ArrowLeft") video.currentTime = Math.max(0, video.currentTime - 10);
  else if (e.key === "ArrowRight") video.currentTime += 10;
  else if (e.key === "f") document.fullscreenElement ? document.exitFullscreen() : player.requestFullscreen();
  else if (e.key === "m") video.muted = !video.muted;
  else return;
  e.preventDefault();
});

// Routing: #home, #movies, #series, #watching, #watched, #kept, #lists,
// #lists/<id>, #search, #title/<key>[/<season>]: each page an address of
// its own, so Back retraces them, and a title opens in a new tab or is
// bookmarked.

/// Each shelf's place as it was left (where it was scrolled, and the series
/// open), to come back to, as the Mac's shelves keep theirs: by Back from a
/// title's page, or choosing it again.
const places = new Map();
// The browser's own restoring would scroll before a shelf's rebuilt.
history.scrollRestoration = "manual";
/// The page shown, whose place is kept as another's shown.
let shownHash = null;

/// Puts a shelf back as it was left: its series open again, at once, and
/// scrolled there once enough of it is built (a screenful comes first, the
/// rest a slice a frame).
function restore(place, mine) {
  let frames = 0;
  const step = () => {
    if (mine !== showing) return;
    if (place.open && !open) {
      const tile = main.querySelector(`[data-series="${CSS.escape(place.open)}"]`);
      if (tile) toggleBand(tile, tile.series, true);
    }
    const built = document.documentElement.scrollHeight >= place.y + innerHeight;
    if ((built && (!place.open || open)) || ++frames > 120) return scrollTo(0, place.y);
    requestAnimationFrame(step);
  };
  step();
}

/// Shows the page the address names: a shelf put back as it was left, or
/// shown again as its data changes, keeping its place (its changed tiles
/// drawn again); `fromTop`, as a new search, order, or grouping, anew from
/// its top, as the Mac's starts.
async function route(how) {
  const mine = ++showing;
  // Wide has no Home, its rows being the sidebar's shelves.
  const hash = decodeURIComponent(location.hash.slice(1)) || (wide.matches ? "movies" : "home");
  // Watching was In Progress.
  if (hash === "in-progress") return location.replace("#watching");
  const fromTop = how?.fromTop === true;
  if (shownHash && !shownHash.startsWith("title/") && !(fromTop && shownHash === hash)) {
    places.set(shownHash, { y: scrollY, open: open?.key });
    // Kept whole only; one still being built is built anew.
    kept = main.querySelector("[data-filling]") ? null : { hash: shownHash, nodes: [...main.childNodes], makeup: shownMakeup, y: scrollY, open };
  }
  if (fromTop) {
    places.delete(hash);
    kept = null;
  }
  shownHash = hash;
  shownShelf = hash.startsWith("title/") ? "title" : hash.startsWith("lists/") ? "list" : shelves[hash] ? hash : "home";
  if (shownShelf !== "title") lastShelf = shownShelf === "home" ? "home" : hash;
  document.body.dataset.shelf = shownShelf;
  markShown();
  // The tab shows chosen before its shelf is built, so the click answers at once.
  await new Promise((r) => requestAnimationFrame(() => setTimeout(r)));
  if (mine !== showing) return;
  let parts;
  let reused = null;
  try {
    if (hash.startsWith("title/")) {
      orderMenu.hidden = true;
      grouping.hidden = true;
      const rest = hash.slice("title/".length);
      // A title key has four segments; a fifth is the season.
      const segments = rest.split("/");
      const key = segments.slice(0, 4).join("/");
      const season = segments.length > 4 ? Number(segments[4]) : null;
      // Cleared first, so a problem the page finds stays.
      shelfStatus = "";
      show(keepingLine());
      shelfTitle.textContent = "";
      parts = await titlePage(key, season);
      // Another route shown meanwhile: nothing of this one's.
      if (mine !== showing) return;
      shownMakeup = null;
    } else {
      shownList = shownShelf === "list" ? library.lists.find((l) => l.id === hash.slice("lists/".length)) || null : null;
      const shelf = shownShelf;
      // Home's and Lists' rows have orders of their own.
      orderMenu.hidden = shelf === "home" || shelf === "lists";
      grouping.hidden = shelf !== "series";
      grouping.querySelector("input").checked = groupsSeries();
      open = null;
      shownMakeup = makeup(shelf);
      reused = kept?.hash === hash && kept.makeup === shownMakeup ? kept : null;
      kept = null;
      const order = orderOf(orderKey());
      orderMenu.value = order.by + (order.reversed ? " reversed" : "");
      // A list's page names it in its heading, with what's done to it.
      shelfTitle.textContent = shelf === "list" ? "" : shelfNames[shelf];
      parts = reused ? reused.nodes : shelves[shelf]();
      shelfStatus = counts(shelf);
      show(keepingLine() || shelfStatus);
    }
  } catch (e) {
    if (mine !== showing) return;
    parts = [empty("Couldn't load it.")];
    problem(e.message);
  }
  if (mine !== showing) return;
  main.replaceChildren(...parts);
  abandonCovers();
  if (reused) {
    // Put back as it was, its changed tiles drawn again.
    open = reused.open;
    patch();
    placeBand();
    return scrollTo(0, reused.y);
  }
  const place = hash.startsWith("title/") ? null : places.get(hash);
  if (place) restore(place, mine);
  else scrollTo(0, 0);
  // The Search tab, chosen, is for typing.
  if (shownShelf === "search" && !wide.matches && !search.value) search.focus();
}

/// The shelf shown (`movies`, `list` for a list's page, `title` for a
/// title's), the page last shown that wasn't a title's, and their names.
let shownShelf = null;
let lastShelf = null;
const shelfNames = {
  home: "Home",
  movies: "Movies",
  series: "Series",
  watching: "Watching",
  watched: "Watched",
  kept: "Kept",
  lists: "Lists",
  search: "Search",
};

/// What a shelf's order is kept as: each list's its own.
function orderKey() {
  return shownShelf === "list" ? shownHash : shownShelf;
}

/// Marks the shelf shown in the sidebar, and its tab in the tab bar (a
/// list's page the Lists tab's; Watching's, Watched's, and Kept's Home's,
/// whose rows and links lead to them); a title's page, the shelf it was
/// opened from.
function markShown() {
  const at = shownShelf === "title" ? lastShelf : shownHash;
  markCurrent("#sidebar [data-shelf]", (a) => a.dataset.shelf === at);
  const tab = !at ? null : at.startsWith("lists") ? "lists" : ["watching", "watched", "kept"].includes(at) ? "home" : at;
  markCurrent("#tabs [data-tab]", (a) => a.dataset.tab === tab);
}

/// Marks the one of `selector`'s links that `current` picks as the page.
function markCurrent(selector, current) {
  for (const a of document.querySelectorAll(selector)) current(a) ? a.setAttribute("aria-current", "page") : a.removeAttribute("aria-current");
}

// Across the width, search applies or doesn't, and Home's shown or not.
wide.addEventListener("change", () => route());

grouping.querySelector("input").addEventListener("change", (e) => {
  localStorage.setItem("groupsSeries", String(e.target.checked));
  route({ fromTop: true });
});

orderMenu.addEventListener("change", () => {
  const [by, reversed] = orderMenu.value.split(" ");
  chooseOrder(orderKey(), { by, reversed: reversed === "reversed" });
  route({ fromTop: true });
});

search.addEventListener("input", () => {
  // From a title's page, the shelf it was opened from.
  if (shownShelf === "title") location.hash = "#" + (lastShelf && lastShelf !== "home" ? lastShelf : "movies");
  else route({ fromTop: true });
});
addEventListener("hashchange", route);

(async () => {
  try {
    await reload();
  } catch (e) {
    problem(e.message);
  }
  route();
})();
