// Cinematheque's web client: browses the library its server shares, and
// plays from its sources. The server is this device; what's watched, and
// the watchlist, are its person's.
"use strict";

const main = document.getElementById("main");
const search = document.getElementById("search");
const statusBar = document.getElementById("status");

/// What the server last said: tiles, and the watchlist's keys.
let library = { tiles: [], watchlist: new Set() };

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

async function reload() {
  const got = await api("tiles");
  library = { tiles: got.tiles, watchlist: new Set(got.watchlist) };
}

// Tiles.

/// A tile's key on the watchlist: a movie's title key, or `<key>#<season>`.
function listKey(tile) {
  return tile.season == null ? tile.key : `${tile.key}#${tile.season}`;
}

function coverURL(cover) {
  const q = new URLSearchParams({ url: cover.url, offset: cover.offset, length: cover.length, stamp: cover.stamp });
  return "api/cover?" + q;
}

function thumbURL(hash) {
  return "api/thumb?" + new URLSearchParams({ hash });
}

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
/// connections to the server queued them behind one another.
const nearScreen = new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) {
    nearScreen.unobserve(e.target);
    e.target.load();
  }
}, { rootMargin: "1000px 0px" });

/// A tile; under its series' name (`underSeries`), a season says only which.
function tileView(tile, underSeries = false) {
  const cover = el("div", { class: "cover" });
  if ((tile.thumb && tile.thumb !== "-") || tile.cover) {
    cover.load = () => {
      if (tile.thumb && tile.thumb !== "-") cover.style.backgroundImage = `url("${thumbURL(tile.thumb)}")`;
      if (!tile.cover) return;
      const img = el("img", { alt: "", decoding: "async", src: coverURL(tile.cover) });
      // Shown at once, once loaded, without a fade, over its placeholder.
      img.style.visibility = "hidden";
      img.onload = () => { img.style.visibility = ""; };
      img.onerror = () => img.remove();
      // Under the marks (star, check, progress), which come before it.
      cover.prepend(img);
    };
    nearScreen.observe(cover);
  }
  if (!tile.thumb && !tile.cover) {
    cover.append(el("div", { class: "initials" }, tile.name));
  }
  if (library.watchlist.has(listKey(tile))) cover.append(el("span", { class: "badge star", title: "On Watchlist" }, "★"));
  if (tile.watched) cover.append(el("span", { class: "badge watched", title: "Watched" }, "✓"));
  else if (tile.progress > 0) cover.append(el("div", { class: "meter" }, el("span", { style: `width:${Math.round(tile.progress * 100)}%` })));
  const href = "#title/" + encodeURIComponent(tile.key) + (tile.season == null ? "" : "/" + tile.season);
  return el("a", { class: `tile${tile.season == null ? "" : " season"}${tile.unavailable ? " unavailable" : ""}`, href },
    cover,
    el("div", { class: "name" }, underSeries ? seasonName(tile.season) : tile.name),
    underSeries ? null : el("div", { class: "sub" }, tile.season == null ? (tile.year ? String(tile.year) : "") : seasonName(tile.season)),
  );
}

function seasonName(season) {
  return season === 0 ? "Specials" : `Season ${season}`;
}

/// Tiles matching the search, by name.
function matching(tiles) {
  const words = search.value.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return tiles;
  return tiles.filter((t) => words.every((w) => t.name.toLowerCase().includes(w)));
}

function byName(a, b) {
  return a.name.localeCompare(b.name) || (a.year || 0) - (b.year || 0) || (a.season || 0) - (b.season || 0);
}

/// Which showing of a page is the latest, so building an older one stops.
let showing = 0;

/// Appends what `make` makes of each of `items` to `parent`: a screenful at
/// once, the rest a slice a frame, so a shelf of thousands shows at once and
/// the page never stops answering.
function fill(parent, items, make) {
  const mine = showing;
  let i = 0;
  const slice = (n) => {
    if (mine !== showing) return;
    for (const end = Math.min(items.length, i + n); i < end; i++) parent.append(make(items[i]));
    if (i < items.length) requestAnimationFrame(() => slice(400));
  };
  slice(80);
  return parent;
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

const shelves = {
  home: () => {
    const all = matching(library.tiles);
    const going = all.filter((t) => t.started && !t.watched);
    const listed = all.filter((t) => library.watchlist.has(listKey(t)));
    const parts = [];
    if (going.length) parts.push(el("h2", {}, "Continue Watching"), ...shelfGrid(going));
    if (listed.length) parts.push(el("h2", {}, "Watchlist"), ...shelfGrid(listed.sort(byName)));
    return parts.length ? parts : [empty("Nothing in progress or on your watchlist yet.")];
  },
  movies: () => {
    const t = matching(library.tiles.filter((t) => t.kind === "movie")).sort(byName);
    return t.length ? [grid(t)] : [empty("No movies.")];
  },
  series: () => {
    const t = matching(library.tiles.filter((t) => t.kind === "series")).sort(byName);
    return t.length ? seriesGrid(t) : [empty("No series.")];
  },
  watchlist: () => {
    const t = matching(library.tiles.filter((t) => library.watchlist.has(listKey(t)))).sort(byName);
    return t.length ? shelfGrid(t) : [empty("Nothing on your watchlist.")];
  },
  // Played, split in two, as the Mac's sidebar has it.
  "in-progress": () => {
    const t = matching(library.tiles.filter(onShelf["in-progress"])).sort(byName);
    return t.length ? shelfGrid(t) : [empty("What you're watching shows here.")];
  },
  watched: () => {
    const t = matching(library.tiles.filter(onShelf.watched)).sort(byName);
    return t.length ? shelfGrid(t) : [empty("What you've watched shows here.")];
  },
};

function empty(text) {
  return el("p", { class: "empty" }, text);
}

/// Each shelf's tiles, before a search.
const onShelf = {
  home: (t) => (t.started && !t.watched) || library.watchlist.has(listKey(t)),
  movies: (t) => t.kind === "movie",
  series: (t) => t.kind === "series",
  watchlist: (t) => library.watchlist.has(listKey(t)),
  "in-progress": (t) => t.started && !t.watched,
  watched: (t) => t.watched,
};

/// How many a shelf holds, for the status line, as the Mac's says it:
/// "4,000 movies", "300 series, 1,200 seasons, 15,000 episodes", or with a
/// search, "12 of 4,000 movies match “zoo”".
function counts(shelf) {
  const all = library.tiles.filter(onShelf[shelf] || onShelf.home);
  const titles = new Set(all.map((t) => t.key)).size;
  const noun = shelf === "movies" ? (titles === 1 ? "movie" : "movies") : shelf === "series" ? "series" : titles === 1 ? "title" : "titles";
  const n = (x) => x.toLocaleString();
  if (search.value.trim()) {
    const found = new Set(matching(all).map((t) => t.key)).size;
    return `${n(found)} of ${n(titles)} ${noun} match “${search.value.trim()}”`;
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
  const listed = library.watchlist.has(isSeries ? `${key}#${season}` : key);
  const allWatched = items.length > 0 && items.every((i) => i.watched);
  const nextLabel = !items[next] ? "Play" : isSeries
    ? `${resuming ? "Resume" : "Play"} ${items[next].label}`
    : resuming ? "Resume" : "Play";

  const play = (index, fromStart) => playQueue(detail, items, index, quality, fromStart);
  // Playing, on a row of its own, filled, Start Over before Resume, as a
  // player's timeline starts at its leading edge: the marks, quieter, at
  // its end.
  const actions = el("div", { class: "actions" },
    resuming ? el("button", { type: "button", disabled: !quality, onclick: () => play(next, true) }, "⏮ Start Over") : null,
    el("button", { class: "primary", type: "button", disabled: !quality, onclick: () => play(next) }, "▶ " + nextLabel),
    el("span", { class: "spacer" }),
    el("button", { class: "mark", type: "button", "aria-pressed": listed, onclick: async () => { await api("watchlist", { key: isSeries ? `${key}#${season}` : key, on: !listed }); await reload(); route(); } },
      listed ? "★ On Watchlist" : "☆ Watchlist"),
    el("button", { class: "mark", type: "button", "aria-pressed": allWatched, onclick: async () => {
      for (const i of items) await api("watched", { item: `${key}/${i.key}`, watched: !allWatched });
      await reload(); route();
    } }, allWatched ? "✓ Watched" : "○ Unwatched"),
  );
  if (!quality) problem("None of its copies plays in a browser (MKV and ISO files don't).");

  // The quality, by its short label, with its full name as its sources give it.
  const short = shortNames(qualities);
  const qualityPicker = qualities.length > 1 ? el("label", { class: "picker" }, "Quality ",
    el("select", {
      title: qualities.find((q) => q.label === quality)?.name,
      onchange: (e) => { chosenQuality.set(key, e.target.value); route(); },
    }, qualities.map((q) => el("option", { value: q.label, selected: q.label === quality, title: q.name }, short.get(q.label))))) : null;

  // The season, unless its pop-up says which.
  const facts = [isSeries && seasons.length < 2 ? seasonName(season) : null, detail.year, detail.fields.genre, detail.fields.network,
    !isSeries && items[0]?.fields.duration ? formatTime(Number(items[0].fields.duration)) : null].filter(Boolean).join(" · ");
  const body = [
    el("h1", {}, detail.name),
    facts ? el("div", { class: "facts" }, facts) : null,
    actions,
    !isSeries && items.length === 1 ? progressRow(detail, items[0]) : null,
    detail.fields.description && !isSeries ? el("p", { class: "description" }, detail.fields.description) : null,
  ];
  if (isSeries) {
    // Which season, and its quality, in the heading of the episodes they choose.
    const seasonPicker = seasons.length > 1 ? el("select", {
      "aria-label": "Season",
      onchange: (e) => { location.hash = `#title/${encodeURIComponent(key)}/${e.target.value}`; },
    }, seasons.map((s) => el("option", { value: s, selected: s === season }, seasonName(s)))) : null;
    body.push(el("div", { class: "heading" }, el("h2", {}, "Episodes"), seasonPicker, el("span", { class: "spacer" }), qualityPicker));
    body.push(el("ul", { class: "episodes" }, items.map((item, n) => el("li", { class: item.watched ? "watched" : null },
      el("button", { class: "play", type: "button", "aria-label": "Play", disabled: !quality, onclick: () => play(n) }, "▶"),
      el("span", { class: "title" }, itemTitle(detail, item)),
      el("span", { class: "time" }, item.fields.duration ? formatTime(Number(item.fields.duration)) : ""),
      progressRow(detail, item),
      item.fields.description ? el("span", { class: "desc" }, item.fields.description) : null,
    ))));
  } else if (items.length > 1) {
    body.push(el("div", { class: "heading" }, el("h2", {}, "Versions"), el("span", { class: "spacer" }), qualityPicker));
    body.push(el("ul", { class: "episodes" }, items.map((item, n) => el("li", {},
      el("button", { class: "play", type: "button", "aria-label": "Play", disabled: !quality, onclick: () => play(n) }, "▶"),
      el("span", { class: "title" }, itemTitle(detail, item)),
      el("span", { class: "time" }, ""),
    ))));
  } else if (qualityPicker) {
    body.push(el("div", { class: "heading" }, el("span", { class: "spacer" }), qualityPicker));
  }
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

/// Reads the episodes shown that a crawl didn't describe (their titles and
/// descriptions, from their files), one at a time, then shows the page again.
async function describe(detail, items) {
  const page = location.hash;
  let any = false;
  for (const item of items) {
    const key = `${detail.key}/${item.key}`;
    if (item.season == null || item.fields.title || described.has(key)) continue;
    described.add(key);
    if (location.hash !== page || session) return;
    await api("describe", { item: key }).then(() => { any = true; }).catch(() => {});
  }
  if (any && location.hash === page && !session) route();
}

// Playing.

const player = document.getElementById("player");
const video = document.getElementById("video");
const curtain = document.getElementById("curtain");
const fade = 500;
/// How much before where it was left resuming starts.
const replay = 4000;
let session = null;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

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
/// by the server (the one whose server answers first), then the rest.
async function copiesOf(item, quality) {
  const chosen = item.qualities.find((q) => q.label === quality);
  const others = item.qualities.filter((q) => q !== chosen && rank(q) >= 0);
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
  const urls = await copiesOf(item, me.quality);
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
    const done = (ok) => {
      video.removeEventListener("canplay", onReady);
      video.removeEventListener("error", onError);
      ok ? resolve() : reject(new Error("didn't load"));
    };
    const onReady = () => done(true);
    const onError = () => done(false);
    video.addEventListener("canplay", onReady);
    video.addEventListener("error", onError);
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

// Routing: #home, #movies, #series, #watchlist, #in-progress, #watched,
// #title/<key>[/<season>].

async function route() {
  const mine = ++showing;
  const hash = decodeURIComponent(location.hash.slice(1)) || "home";
  for (const a of document.querySelectorAll("nav a")) a.toggleAttribute("aria-current", a.dataset.shelf === hash);
  for (const a of document.querySelectorAll("nav a[aria-current]")) a.setAttribute("aria-current", "page");
  // The tab shows chosen before its shelf is built, so the click answers at once.
  await new Promise((r) => requestAnimationFrame(() => setTimeout(r)));
  if (mine !== showing) return;
  let parts;
  try {
    if (hash.startsWith("title/")) {
      const rest = hash.slice("title/".length);
      // A title key has four segments; a fifth is the season.
      const segments = rest.split("/");
      const key = segments.slice(0, 4).join("/");
      const season = segments.length > 4 ? Number(segments[4]) : null;
      // Cleared first, so a problem the page finds stays.
      show("");
      parts = await titlePage(key, season);
    } else {
      parts = (shelves[hash] || shelves.home)();
      show(counts(shelves[hash] ? hash : "home"));
    }
  } catch (e) {
    parts = [empty("Couldn't load it.")];
    problem(e.message);
  }
  if (mine !== showing) return;
  main.replaceChildren(...parts);
  scrollTo(0, 0);
}

search.addEventListener("input", () => {
  if (location.hash.startsWith("#title/")) location.hash = "#movies";
  else route();
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
