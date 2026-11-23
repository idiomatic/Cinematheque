// Setup and settings: creating a library or joining one, and what the
// Mac's Settings change (names, people, devices, sources, how often
// they're looked through, addresses, refreshing, and leaving). Only a
// browser on the server's own computer acts as its device, unless it's
// started with --permissive; any other is told so.

/// Where this device stands (setup.zig's `status`): whether this browser
/// acts as it, whether it has a library, and its names.
let standing = null;

/// Shows setup, or why this browser can't act as this device, unless it
/// has a library this browser acts in; whether it does.
async function gate() {
  standing = await api("status");
  if (standing.admin && standing.library) return true;
  document.body.classList.add("outside");
  main.replaceChildren(standing.admin ? setupPage() : outsidePage());
  return false;
}

/// Why a browser elsewhere on the network can't act as this device yet.
function outsidePage() {
  const local = `http://localhost:${location.port || 80}/`;
  return el("section", { class: "welcome" }, brand(),
    el("h1", {}, "Open Cinematheque on its own computer"),
    el("p", {}, "This server acts only for a browser on the computer it runs on: open ", el("code", {}, local), " there, or through an SSH tunnel to it."),
    el("p", { class: "dim" }, "To let every browser on the network act as it, start it with ", el("code", {}, "--permissive"), "."));
}

/// The app's mark and name, as the sidebar shows them.
function brand() {
  const mark = document.querySelector(".brand svg").cloneNode(true);
  // Its gradient its own: the sidebar's, hidden here, draws nothing.
  mark.querySelector("linearGradient").id = "brand-red-welcome";
  mark.querySelector("rect").setAttribute("fill", "url(#brand-red-welcome)");
  return el("div", { class: "brand" }, mark, "Cinematheque");
}

/// Create a Library, or Join a Library by a code, as the apps' welcome
/// offers them; then the library.
function setupPage() {
  const page = el("section", { class: "welcome" }, brand());
  const choices = () => page.replaceChildren(brand(),
    el("button", { type: "button", class: "choice", onclick: create },
      el("strong", {}, "Create a Library"), el("span", {}, "Start a new library of the videos on your network.")),
    el("button", { type: "button", class: "choice", onclick: join },
      el("strong", {}, "Join a Library"), el("span", {}, "Add this server to a library you, or someone else, already have.")));
  async function create() {
    await api("setup-create", {});
    // Its sources first, as a new library has none.
    location.replace("#settings");
    location.reload();
  }
  async function join() {
    const code = await api("setup-join", {});
    let waiting = true;
    page.replaceChildren(brand(),
      el("h1", {}, "Join a Library"),
      el("p", {}, "On a device already in the library, add a new device, and enter this code:"),
      codeView(code),
      el("p", { class: "dim" }, "On a Mac, in Settings › Devices; on an Apple TV, in Settings › Your Devices, or People › Add Someone; or ", el("code", {}, `cinematheque person pair ${code}`), "."),
      el("button", { type: "button", onclick: async () => {
        waiting = false;
        await api("setup-join-stop", {});
        choices();
      } }, "Back"));
    // Joined once a member's device has added this one.
    while (waiting) {
      await new Promise((r) => setTimeout(r, 1000));
      const now = await api("status").catch(() => null);
      if (now?.library) return location.reload();
      if (now?.joining && now.joining !== code) return join();
    }
  }
  choices();
  return page;
}

/// A code, a digit to a box, in two groups of three, as it's typed.
function codeView(code) {
  const digits = (s) => [...s].map((d) => el("span", {}, d));
  return el("div", { class: "code", "aria-label": `Code ${code}` }, el("div", {}, ...digits(code.slice(0, 3))), el("div", {}, ...digits(code.slice(3))));
}

/// Settings, as the Mac's panes have them, on one page.
async function settingsPage() {
  const s = await api("settings");
  const page = el("div", { class: "settings" });
  const again = async () => page.replaceChildren(...(await settingsPage()).flatMap((p) => [...p.childNodes]));
  /// Does `name` with `body`, then shows settings again; a failure said.
  const act = (name, body) => api(name, body).then(again, (e) => problem(said(e)));
  const nameOf = (x, fallback) => x.name || fallback;

  // Names.
  const you = s.members.find((m) => m.you);
  const thisDevice = s.devices.find((d) => d.this);
  page.append(section("Names", "Names everyone in the library sees.",
    field("Your name", you.name, (name) => act("name-person", { key: you.key, name })),
    field("This server’s name", thisDevice.name || standing.host, (name) => act("name-device", { key: thisDevice.key, name }))));

  // People, and this person's devices: their lists shown again in place as
  // one's added (while adding goes on) or removed, a note under each saying
  // what was removed, and what comes of it.
  const peopleNote = el("p", { class: "dim note", role: "status" });
  const devicesNote = el("p", { class: "dim note", role: "status" });
  const shownAgain = async () => {
    const now = await api("settings");
    peopleList.replaceChildren(...people(now));
    devicesList.replaceChildren(...devices(now));
  };
  /// Removes one, its row saying so meanwhile, then says it's done.
  async function remove(rowOf, name, body, note, said_) {
    rowOf.querySelectorAll("button").forEach((b) => { b.disabled = true; });
    rowOf.querySelector(".dim").textContent = "Removing…";
    try {
      await api(name, body);
      note.textContent = said_;
      await shownAgain();
    } catch (e) {
      problem(said(e));
      await shownAgain();
    }
  }
  const people = (s) => s.members.map((m) => {
    const r = row(nameOf(m, "Someone unnamed"), [m.founder ? "Founder" : null, m.you ? "You" : null].filter(Boolean).join(", "),
      m.you || m.founder ? null : button("Remove…", () => confirm(`Remove ${nameOf(m, "them")} from the library? They come back only by joining again, as someone new.`) &&
        remove(r, "member-remove", { key: m.key }, peopleNote, `Removed ${nameOf(m, "them")}. Their devices leave the library as each next syncs.`)));
    return r;
  });
  const devices = (s) => s.devices.map((d) => {
    const r = row(nameOf(d, "Unnamed device"), d.this ? "This server" : "",
      d.this ? null : el("span", {},
        button("Rename…", () => { const name = prompt("Name", d.name || ""); if (name) act("name-device", { key: d.key, name }); }),
        button("Remove", () => remove(r, "device-remove", { key: d.key }, devicesNote, `Removed ${nameOf(d, "the device")}. It leaves the library as it next syncs, in a moment if it’s on; it can join again as a new device.`))));
    return r;
  });
  const peopleList = el("div", {}, ...people(s));
  const devicesList = el("div", {}, ...devices(s));
  // A note says only what was done last: adding (or starting to) clears it.
  const quiet = () => {
    peopleNote.textContent = "";
    devicesNote.textContent = "";
  };
  const added = () => {
    quiet();
    return shownAgain();
  };
  page.append(section("People", null, peopleList, peopleNote, pairing("Add Someone", "join", added, quiet)));
  page.append(section("Your Devices", null, devicesList, devicesNote, pairing("Add a Device", "pair", added, quiet)));

  // Sources.
  const addServer = el("input", { type: "url", placeholder: "http://nas.local/videos/", "aria-label": "Server address" });
  page.append(section("Sources", "Folders and servers of videos. Cinematheque only reads them.",
    ...s.sources.map((src) => el("div", { class: "source" },
      row(decodeURI(src.url), src.managed ? "A device’s downloads" : `${src.copies} ${src.copies === 1 ? "video" : "videos"}`,
        src.managed ? null : button("Remove…", () => confirm(`Remove ${decodeURI(src.url)}? Its ${src.copies} videos leave the library on every device; its files stay where they are.`) && act("source-remove", { id: src.id }))),
      ...src.unavailable.map((u) => row(`/${u.dir} is unavailable`, `since ${new Date(u.since_ms).toLocaleDateString()}`,
        button("Remove Videos", () => act("unavailable-remove", { id: src.id, dir: u.dir })))))),
    s.media && !s.media.added ? el("div", { class: "line" }, button(`Add This Server’s Folder (${s.media.dir})`, () => act("source-add-media", {}))) : null,
    el("form", { class: "line", onsubmit: (e) => { e.preventDefault(); act("source-add", { url: addServer.value }); } }, addServer, el("button", { type: "submit" }, "Add Server"))));

  // Looking for new videos.
  const every = el("select", { "aria-label": "Look for new videos", onchange: () => act("crawl-every", { hours: Number(every.value) }) },
    ...[[1, "Every Hour"], [3, "Every 3 Hours"], [24, "Every Day"], [168, "Every Week"], [0, "Manually"]].map(([h, label]) => el("option", { value: h, selected: h === s.crawl_every }, label)));
  const refreshing = el("p", { class: "dim", role: "status" });
  page.append(section("Looking for New Videos", "How often devices look through the sources by themselves (a NAS’s disks wake each time). Refresh Library looks at once; Refresh Fully also reads folders whose files changed in place, as retagging does.",
    el("div", { class: "line" }, every),
    el("div", { class: "line" }, button("Refresh Library", () => startRefresh("refresh")), button("Refresh Fully", () => startRefresh("refresh-fully"))),
    refreshing));
  showRefreshing(refreshing, s.refreshing);
  async function startRefresh(name) {
    await api(name, {}).catch((e) => problem(said(e)));
    followRefresh(refreshing);
  }
  if (s.refreshing.phase !== "idle") followRefresh(refreshing);

  // Advanced: devices by address.
  const address = el("input", { type: "url", placeholder: "http://hal.local:8008/", "aria-label": "Device address" });
  page.append(section("Devices by Address", "Devices this one can’t find on the network, which it syncs with too; on this server only.",
    ...s.addresses.map((u) => row(u, "", button("Forget", () => act("address-forget", { url: u })))),
    el("form", { class: "line", onsubmit: (e) => { e.preventDefault(); act("address-add", { url: address.value }); } }, address, el("button", { type: "submit" }, "Add Address"))));

  // Leaving.
  page.append(section("Leave This Library", "This server forgets the library, and can then create or join one afresh. What it added stays in the library.",
    el("div", { class: "line" }, button("Leave This Library…", () => leaveLibrary(s)))));
  return [page];
}

/// A settings section: its heading, an explanation, and its rows.
function section(name, note, ...rows) {
  return el("section", {}, el("h2", {}, name), note ? el("p", { class: "dim" }, note) : null, ...rows);
}

/// A row: what it is, a note at its end, and what's done to it.
function row(name, note, ...actions) {
  return el("div", { class: "row" }, el("span", { class: "name" }, name), el("span", { class: "dim" }, note || ""), ...actions);
}

function button(label, onclick) {
  return el("button", { type: "button", onclick }, label);
}

/// A name, saved as it's changed.
function field(label, value, save) {
  const input = el("input", { value: value || "", autocomplete: "off", onchange: () => input.value.trim() && save(input.value.trim()) });
  return el("label", { class: "row" }, el("span", { class: "name" }, label), input);
}

/// What went wrong, in words (an API failure is `name: status ErrorName`).
function said(e) {
  const why = String(e.message).split(" ").pop();
  return {
    WrongCode: "That isn’t the code the new device shows.",
    Closed: "That device stopped after too many wrong codes: it shows a new one.",
    TooManyWrongCodes: "That device stopped after too many wrong codes: it shows a new one.",
    BadAddress: "That isn’t a web address (http:// or https://, with a host).",
    NotFounder: "Only the library’s founder can do that.",
    FounderIsPermanent: "The founder can’t be removed.",
    FoundersDevice: "Only the founder can remove the founder’s devices.",
    ThisDevice: "That’s this server.",
    NoOneReached: "No other device of the library could be reached to take the change: try again once one is on.",
    Busy: "Something else is under way: try again once it’s done.",
  }[why] || e.message;
}

/// Adding a new device by the code it shows: `kind` is `pair` (this
/// person's) or `join` (a new member's). Opened by its button, which it
/// takes the place of; it looks for new devices nearby again and again,
/// each listed with a box for its code (a row kept as it's typed in, as
/// the list changes around it), so one after another can be added, each
/// told to `added` (which shows it), until Cancel (Done, once one's added)
/// closes it, as a sheet's button does. One added isn't listed again, as
/// it may advertise its offer a moment longer. `opened` is told as it opens.
function pairing(label, kind, added, opened) {
  const box = el("div", { class: "pairing", hidden: true });
  const open = button(label, () => {
    opened();
    open.hidden = true;
    box.hidden = false;
    look();
  });
  // Which look is current, so one going on after Cancel stops; and the
  // devices added since it opened, by address.
  let looking = 0;
  const taken = new Set();
  const cancel = () => {
    looking++;
    box.hidden = true;
    box.replaceChildren();
    open.hidden = false;
    open.focus();
  };
  async function look() {
    const mine = ++looking;
    const status = el("p", { class: "dim", role: "status" }, "Looking for new devices nearby…");
    const close = button("Cancel", cancel);
    // Said in place of looking, as a device is added.
    let said = "";
    const addedOne = (name) => {
      said = `Added ${name || "a device"}.`;
      status.textContent = said;
      close.textContent = "Done";
    };
    const list = el("div");
    const rows = new Map();
    // A device it can't find, by the address its command line prints.
    const address = el("input", { type: "url", placeholder: "http://new.local:54863/pair", "aria-label": "Its address" });
    const byAddress = codeRow(address, () => address.value, "", () => {
      address.value = "";
      addedOne("");
    });
    byAddress.hidden = true;
    const toggle = button("Add by Address…", () => {
      byAddress.hidden = false;
      toggle.hidden = true;
      address.focus();
    });
    box.replaceChildren(
      el("p", { class: "dim" }, `On ${kind === "pair" ? "your" : "their"} new device, choose Join a Library; it shows here, with a code to enter.`),
      list, status, byAddress,
      el("div", { class: "line" }, toggle, close));
    taken.clear();
    while (mine === looking && box.isConnected) {
      const offering = await api("nearby").catch(() => null);
      if (mine !== looking) return;
      if (offering) {
        const now = new Set(offering.map((o) => o.url));
        // Gone ones go, but one being typed into stays.
        for (const [url, row] of rows) if (!now.has(url) && !row.contains(document.activeElement)) {
          row.remove();
          rows.delete(url);
        }
        for (const o of offering) if (!rows.has(o.url) && !taken.has(o.url)) {
          const row = codeRow(o.name, () => o.url, o.name, () => {
            taken.add(o.url);
            row.remove();
            rows.delete(o.url);
            addedOne(o.name);
          });
          rows.set(o.url, row);
          list.append(row);
        }
        status.textContent = said || (rows.size ? "" : "Looking for new devices nearby…");
      }
      await sleep(1000);
    }
  }
  /// A device's row: its name (or a box for its address), and a box for
  /// its code; `onAdded` once it's added.
  function codeRow(name, url, named, onAdded) {
    const code = el("input", { inputmode: "numeric", pattern: "[0-9]{6}", maxlength: 6, placeholder: "Code", "aria-label": "Code", class: "code-input", required: true });
    return el("form", { class: "row", onsubmit: async (e) => {
      e.preventDefault();
      try {
        await api("pair", { url: url(), code: code.value, kind, name: named });
        code.value = "";
        onAdded();
        added();
      } catch (err) {
        code.value = "";
        problem(said(err));
      }
    } }, typeof name === "string" ? el("span", { class: "name" }, name) : name, code, el("button", { type: "submit", class: "primary" }, "Add"));
  }
  return el("div", {}, el("div", { class: "line" }, open), box);
}

/// How Refresh Library is going, in `line`.
function showRefreshing(line, r) {
  const phase = { syncing: "Catching up…", crawling: `Looking for new videos: ${r.done} of ${r.total} sources`, describing: `Reading covers and descriptions: ${r.done} of ${r.total}` }[r.phase];
  line.textContent = phase || r.said;
}

/// Follows Refresh Library until it's done, then shows the library afresh.
async function followRefresh(line) {
  for (;;) {
    await new Promise((r) => setTimeout(r, 1000));
    const s = await api("settings").catch(() => null);
    if (!s) return;
    showRefreshing(line, s.refreshing);
    if (s.refreshing.phase === "idle") return reload();
  }
}

/// Leaves the library, confirmed first, choosing who takes it over if this
/// person founded it and it would otherwise be left without its founder.
async function leaveLibrary(s, successor) {
  if (!successor && !confirm("Leave this library? This server forgets it, and its other devices stop syncing with it. It can't be undone; it can join again as a new device.")) return;
  try {
    await api("leave", successor ? { successor } : {});
    location.replace("#");
    location.reload();
  } catch (e) {
    if (!String(e.message).endsWith("NeedsSuccessor")) return problem(said(e));
    const others = s.members.filter((m) => !m.you);
    const names = others.map((m, i) => `${i + 1}. ${m.name || m.key.slice(0, 8)}`).join("\n");
    const chosen = Number(prompt(`You founded this library, and this is your only device: who takes it over?\n${names}`, "1"));
    if (others[chosen - 1]) leaveLibrary(s, others[chosen - 1].key);
  }
}
