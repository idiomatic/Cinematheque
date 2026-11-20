import CCinematheque
import Foundation

extension Library {
    // Pairing a new device, by a code it shows, with a member's: to be
    // another of that person's devices, or a new member's.

    /// A new device's offer: the code to show, and whether it's paired (it
    /// has the library) or stopped, after too many wrong codes.
    struct Pairing: Codable, Equatable {
        let code: String?
        let paired: Bool
        let closed: Bool
    }

    /// On this device, before it has a library: offers to be added to one,
    /// as a member's device decides (another of theirs, or a new member's),
    /// with a new code.
    func offerPairing() -> Pairing? {
        // As setup leaves, once paired, its screen may ask once more.
        guard !hasLibrary else { return nil }
        return decode(Pairing.self) { cq_pair_offer($0, Platform.deviceName) }
    }

    /// The offer's state; once paired, this device has its person and library.
    func checkPairing() -> Pairing? {
        guard !hasLibrary else { return nil }
        let state = decode(Pairing.self) { cq_pair_check($0) }
        if state?.paired == true {
            dirty = true
            reload()
        }
        return state
    }

    func stopPairing() {
        if let handle { cq_pair_stop(handle.pointer) }
    }

    /// Pairs the new device `device`, given the code it shows: sends it the
    /// library, and unless it's a new person's (`join`), this person's
    /// secret. Returns who it is (for `welcome`), or what went wrong, in
    /// words.
    func pair(_ device: NearbyDevice, code: String, join: Bool) async -> (Paired?, String?) {
        guard let handle else { return (nil, "The library isn't open.") }
        let url = device.url
        let join: Int32 = join ? 1 : 0
        let name = device.deviceName ?? "The device"
        let (paired, failure): (Paired?, String?) = await Task.detached {
            guard let text = cq_pair(handle.pointer, url, join, code) else { return (nil, String(cString: cq_error())) }
            defer { cq_free(text) }
            return (try? JSONDecoder().decode(Paired.self, from: Data(bytes: text, count: strlen(text))), nil)
        }.value
        guard let failure else { return (paired, nil) }
        switch failure {
        case "WrongCode": return (nil, "That isn't the code \(name) shows. Check it, and try again.")
        case "Closed": return (nil, "\(name) stopped taking codes from this Mac after too many wrong ones. On it, show a new code.")
        default: return (nil, "Couldn't pair with \(name): \(failure).")
        }
    }

    /// Renames another of this person's devices (or this one), for every
    /// device: as when its platform won't tell it its own name.
    func renameDevice(_ key: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let person = status?.person else { return }
        check { cq_name($0, key, person, trimmed) }
    }

    /// Copy racing (see the core's race.zig): `urls`, an item's copies, in
    /// the order to try them, those whose servers answer first; off the
    /// main thread, for up to 1.5 seconds.
    func race(_ urls: [URL]) async -> [URL] {
        guard urls.count > 1, let handle, let json = try? JSONEncoder().encode(urls.map(\.absoluteString)) else { return urls }
        let text = String(decoding: json, as: UTF8.self)
        let ordered: [String]? = await Task.detached {
            guard let out = cq_race(handle.pointer, text) else { return nil }
            defer { cq_free(out) }
            return try? JSONDecoder().decode([String].self, from: Data(bytes: out, count: strlen(out)))
        }.value
        return ordered?.compactMap(URL.init(string:)) ?? urls
    }

    /// Notes a copy that didn't load, so its server is raced last a while.
    func raceLost(_ url: URL) {
        guard let handle else { return }
        cq_race_lost(handle.pointer, url.absoluteString)
    }

    /// Forgets a source's unavailable directory, as if it were deleted: its
    /// copies go, for every device.
    func removeUnavailable(_ source: String, _ dir: String) { check { cq_remove_unavailable($0, source, dir) } }

    /// Removes another of this person's devices from the library: its later
    /// writes are refused, and it's served no more.
    func removeDevice(_ key: String) { check { cq_remove_device($0, key) } }

    /// Takes in a device just paired: names it as it advertised itself, or
    /// as its host is named if that's generic (until it names itself), so
    /// it's among its person's devices at once, and if it's a new person's
    /// (`join`), adds its person as a member.
    func welcome(_ paired: Paired, from device: NearbyDevice, join: Bool) {
        if let name = device.deviceName {
            check(reload: false) { cq_name($0, paired.device, paired.person, name) }
        }
        if join { check(reload: false) { cq_member($0, paired.person, 1) } }
        reload()
    }

    // Names and devices.

    enum Named: String { case person, device }

    /// Names this person or this device, for every device to show in place of
    /// keys, and advertises the new name.
    func setName(_ which: Named, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        check { cq_set_name($0, which.rawValue, trimmed) }
        if servingPort != nil { serve() }
    }

    /// Devices found nearby (listening for 2 seconds) and added by address.
    func nearby() async -> [NearbyDevice] {
        guard let handle else { return [] }
        let data: Data? = await Task.detached {
            guard let text = cq_nearby(handle.pointer) else { return nil }
            defer { cq_free(text) }
            return Data(bytes: text, count: strlen(text))
        }.value
        return data.flatMap { try? JSONDecoder().decode([NearbyDevice].self, from: $0) } ?? []
    }

    /// Adds a device by address (e.g., one off the network), or removes one.
    func setDeviceAddress(_ url: String, _ add: Bool) { check(reload: false) { cq_device_address($0, url, add ? 1 : 0) } }

}
