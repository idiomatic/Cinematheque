//! Cinematheque's core: the replicated library and what devices need to fill
//! and share it.

pub const replica = @import("replica.zig");
pub const sync = @import("sync.zig");
pub const crawl = @import("crawl.zig");
pub const naming = @import("naming.zig");
pub const library = @import("library.zig");
pub const review = @import("review.zig");
pub const serve = @import("serve.zig");
pub const discover = @import("discover.zig");
pub const model = @import("model.zig");
pub const url = @import("url.zig");
pub const mp4 = @import("mp4.zig");
pub const art = @import("art.zig");
pub const jpeg = @import("jpeg.zig");
pub const thumbhash = @import("thumbhash.zig");
pub const store = @import("store.zig");
pub const pair = @import("pair.zig");
pub const host = @import("host.zig");
pub const race = @import("race.zig");
pub const download = @import("download.zig");
pub const views = @import("views.zig");
pub const lists = @import("lists.zig");
pub const version = @import("version.zig");
pub const json = @import("json.zig");
pub const deadline = @import("deadline.zig");

test {
    _ = replica;
    _ = @import("replica_tests.zig");
    _ = sync;
    _ = crawl;
    _ = naming;
    _ = @import("naming_tests.zig");
    _ = @import("library_tests.zig");
    _ = @import("download_tests.zig");
    _ = library;
    _ = review;
    _ = serve;
    _ = discover;
    _ = url;
    _ = mp4;
    _ = art;
    _ = jpeg;
    _ = thumbhash;
    _ = store;
    _ = pair;
    _ = host;
    _ = race;
    _ = download;
    _ = views;
    _ = json;
    _ = @import("deadline.zig");
    _ = @import("version.zig");
    _ = @import("model.zig");
    _ = @import("order.zig");
    _ = @import("lists.zig");
    _ = @import("seal.zig");
    _ = @import("merkle.zig");
    _ = @import("hlc.zig");
    _ = @import("op.zig");
}
