// Routing: #home, #movies, #series, #watching, #watched, #kept, #lists,
// #lists/<id>, #search, #settings, #title/<key>[/<season>]: each page an address of
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
  shownShelf = hash.startsWith("title/") ? "title" : hash.startsWith("lists/") ? "list" : shelves[hash] || hash === "settings" ? hash : "home";
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
    } else if (hash === "settings") {
      orderMenu.hidden = true;
      grouping.hidden = true;
      shelfStatus = "";
      show("");
      shelfTitle.textContent = "Settings";
      parts = await settingsPage();
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
  const tab = !at ? null : at.startsWith("lists") ? "lists" : ["watching", "watched", "kept", "settings"].includes(at) ? "home" : at;
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
  // From a title's page, or Settings, the shelf it was opened from.
  if (shownShelf === "title" || shownShelf === "settings") location.hash = "#" + (lastShelf && lastShelf !== "home" ? lastShelf : "movies");
  else route({ fromTop: true });
});
addEventListener("hashchange", route);

(async () => {
  try {
    // Setup, or why this browser can't act as this device, instead.
    if (!(await gate())) return;
    await reload();
  } catch (e) {
    problem(e.message);
  }
  route();
})();
