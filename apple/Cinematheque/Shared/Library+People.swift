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
        return decode(Pairing.self) { cq_pair_offer($0, Platform.deviceName, Platform.model) }
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

    /// Adds the new device `device` as another of this person's devices,
    /// given the code it shows: sends it the library and this person's
    /// secret. Returns who it is (for `welcome`), or what went wrong, in
    /// words.
    func pairPerson(_ device: NearbyDevice, code: String) async -> (Paired?, String?) {
        await pair(device, code: code) { cq_pair_person($0, $1, $2) }
    }

    /// Adds the new device `device` as a new member's, given the code it
    /// shows: sends it the library alone. Returns who it is (for
    /// `welcomeMember`), or what went wrong, in words.
    func pairMember(_ device: NearbyDevice, code: String) async -> (Paired?, String?) {
        await pair(device, code: code) { cq_pair_member($0, $1, $2) }
    }

    private func pair(_ device: NearbyDevice, code: String, by send: @escaping @Sendable (OpaquePointer, String, String) -> UnsafeMutablePointer<CChar>?) async -> (Paired?, String?) {
        let url = device.url
        let name = device.deviceName ?? "The device"
        let called: (Paired?, String?)? = await apart { handle in
            guard let text = send(handle, url, code) else { return (nil, String(cString: cq_error())) }
            defer { cq_free(text) }
            return (try? JSONDecoder().decode(Paired.self, from: Data(bytes: text, count: strlen(text))), nil)
        }
        guard let (paired, failure) = called else { return (nil, "The library isn't open.") }
        guard let failure else { return (paired, nil) }
        switch failure {
        case "WrongCode": return (nil, "That isn't the code \(name) shows. Check it, and try again.")
        case "Closed": return (nil, "\(name) stopped taking codes from \(Self.thisDevice) after too many wrong ones. On it, show a new code.")
        default: return (nil, "Couldn't pair with \(name): \(failure).")
        }
    }

    /// This device, as a person calls it.
    static var thisDevice: String {
        #if os(tvOS)
        "this Apple TV"
        #elseif os(iOS)
        "this iPhone"
        #else
        "this Mac"
        #endif
    }

    /// Renames another of this person's devices (or this one), for every
    /// device: as when its platform won't tell it its own name.
    func renameDevice(_ key: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let person = status?.person else { return }
        checkAndReload { cq_name($0, key, person, trimmed) }
    }

    /// Copy racing (see the core's race.zig): `urls`, an item's copies, in
    /// the order to try them, those whose servers answer first; off the
    /// main thread, for up to 1.5 seconds.
    func race(_ urls: [URL]) async -> [URL] {
        guard urls.count > 1, let handle else { return urls }
        let strings = urls.map(\.absoluteString)
        let ordered: [String]? = await Task.detached {
            guard let out = withCStrings(strings, { cq_race(handle.pointer, $0, $1) }) else { return nil }
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
    func removeUnavailable(_ source: String, _ dir: String) { checkAndReload { cq_remove_unavailable($0, source, dir) } }

    /// Removes another of this person's devices from the library: its later
    /// writes are refused, and it's served no more.
    func removeDevice(_ key: String) { checkAndReload { cq_remove_device($0, key) } }

    /// Takes in a device just paired: names it as it advertised itself, or
    /// as its host is named if that's generic (until it names itself), so
    /// it's among its person's devices at once.
    func welcome(_ paired: Paired, from device: NearbyDevice) {
        if let name = device.deviceName {
            check { cq_name($0, paired.device, paired.person, name) }
        }
        reloadSoon()
    }

    /// As `welcome`, for a new person's device: adds its person as a member
    /// too.
    func welcomeMember(_ paired: Paired, from device: NearbyDevice) {
        check { cq_member_add($0, paired.person) }
        welcome(paired, from: device)
    }

    // Names and devices.

    enum Named { case person, device }

    /// Names this person or this device, for every device to show in place of
    /// keys, and advertises the new name.
    func setName(_ which: Named, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch which {
        case .person: checkAndReload { cq_set_person_name($0, trimmed) }
        case .device: checkAndReload { cq_set_device_name($0, trimmed) }
        }
        if servingPort != nil { serve() }
    }

    /// Devices found nearby (listening for 2 seconds) and added by address.
    func nearby() async -> [NearbyDevice] {
        let data: Data? = await apart { handle in
            guard let text = cq_nearby(handle) else { return nil }
            defer { cq_free(text) }
            return Data(bytes: text, count: strlen(text))
        } ?? nil
        return data.flatMap { try? JSONDecoder().decode([NearbyDevice].self, from: $0) } ?? []
    }

    /// Adds a device by address (e.g., one off the network).
    func addDeviceAddress(_ url: String) { check { cq_device_address_add($0, url) } }

    /// Forgets an address added.
    func forgetDeviceAddress(_ url: String) { check { cq_device_address_forget($0, url) } }

}
