import AppKit

// MARK: - CGS Private API Declarations

typealias CGSConnectionID = Int32
typealias CGSSpaceID = size_t

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSSpaceGetType")
private func CGSSpaceGetType(_ cid: CGSConnectionID, _ spaceID: CGSSpaceID) -> CGSSpaceType

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(
    _ cid: CGSConnectionID,
    _ mask: CGSSpaceMask,
    _ windowIDs: CFArray
) -> Unmanaged<CFArray>?

// MARK: - CGS Space

/// https://github.com/NUIKit/CGSInternal/blob/c4f6f559d624dc1cfc2bf24c8c19dbf653317fcf/CGSSpace.h#L40
/// converted to Swift
struct CGSSpaceMask: OptionSet {
    let rawValue: UInt32

    static let includesCurrent = CGSSpaceMask(rawValue: 1 << 0)
    static let includesOthers = CGSSpaceMask(rawValue: 1 << 1)
    static let includesUser = CGSSpaceMask(rawValue: 1 << 2)

    static let includesVisible = CGSSpaceMask(rawValue: 1 << 16)

    static let currentSpace: CGSSpaceMask = [.includesUser, .includesCurrent]
    static let otherSpaces: CGSSpaceMask = [.includesOthers, .includesCurrent]
    static let allSpaces: CGSSpaceMask = [.includesUser, .includesOthers, .includesCurrent]
    static let allVisibleSpaces: CGSSpaceMask = [.includesVisible, .allSpaces]
}

/// Represents a unique identifier for a macOS Space (Desktop, Fullscreen, etc).
struct CGSSpace: Hashable, CustomStringConvertible {
    let rawValue: CGSSpaceID

    var description: String {
        "SpaceID(\(rawValue))"
    }

    /// Returns the currently active space.
    static func active() -> CGSSpace {
        let space = CGSGetActiveSpace(CGSMainConnectionID())
        return .init(rawValue: space)
    }

    /// List the spaces for the given window.
    static func list(for windowID: CGWindowID, mask: CGSSpaceMask = .allSpaces) -> [CGSSpace] {
        guard let spaces = CGSCopySpacesForWindows(
            CGSMainConnectionID(),
            mask,
            [windowID] as CFArray
        ) else { return [] }
        guard let spaceIDs = spaces.takeRetainedValue() as? [CGSSpaceID] else { return [] }
        return spaceIDs.map(CGSSpace.init)
    }
}

// MARK: - CGS Space Types

enum CGSSpaceType: UInt32 {
    case user = 0
    case system = 2
    case fullscreen = 4
}

extension CGSSpace {
    var type: CGSSpaceType {
        CGSSpaceGetType(CGSMainConnectionID(), rawValue)
    }

    var screen: NSScreen? {
        guard let displayUUID else { return nil }
        return NSScreen.screens.first { $0.displayUUID == displayUUID }
    }

    static func currentFullscreenScreen(
        frontmostApplicationProcessIdentifier: pid_t?,
        fallbackToSingleDisplay: Bool = false
    ) -> NSScreen? {
        guard let displayUUID = currentFullscreenDisplayUUID(
            frontmostApplicationProcessIdentifier: frontmostApplicationProcessIdentifier,
            managedDisplaySpaces: managedDisplaySpaces(),
            fallbackToSingleDisplay: fallbackToSingleDisplay
        ) else { return nil }

        return NSScreen.screens.first { $0.displayUUID == displayUUID }
    }

    private var displayUUID: UUID? {
        Self.displayUUID(for: self, managedDisplaySpaces: Self.managedDisplaySpaces())
    }

    static func displayUUID(for space: CGSSpace, managedDisplaySpaces: [[String: Any]]) -> UUID? {
        parsedManagedDisplaySpaces(from: managedDisplaySpaces)
            .first { $0.spaceID == space.rawValue }?
            .displayUUID
    }

    static func currentFullscreenDisplayUUID(
        frontmostApplicationProcessIdentifier: pid_t?,
        managedDisplaySpaces: [[String: Any]],
        fallbackToSingleDisplay: Bool = false
    ) -> UUID? {
        let fullscreenDisplaySpaces = parsedManagedDisplaySpaces(from: managedDisplaySpaces)
            .filter { $0.type == .fullscreen }

        if let frontmostApplicationProcessIdentifier,
           let displaySpace = fullscreenDisplaySpaces.first(where: {
               $0.processIdentifier == frontmostApplicationProcessIdentifier
           }) {
            return displaySpace.displayUUID
        }

        guard fallbackToSingleDisplay, fullscreenDisplaySpaces.count == 1 else { return nil }
        return fullscreenDisplaySpaces[0].displayUUID
    }

    private static func managedDisplaySpaces() -> [[String: Any]] {
        guard let spaces = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) else { return [] }
        return spaces.takeRetainedValue() as? [[String: Any]] ?? []
    }

    private static func parsedManagedDisplaySpaces(from rawValue: [[String: Any]]) -> [ManagedDisplaySpace] {
        rawValue.compactMap(ManagedDisplaySpace.init)
    }
}

private struct ManagedDisplaySpace {
    let displayUUID: UUID
    let spaceID: CGSSpaceID?
    let type: CGSSpaceType?
    let processIdentifier: pid_t?

    init?(_ rawValue: [String: Any]) {
        guard
            let displayIdentifier = rawValue["Display Identifier"] as? String,
            let displayUUID = UUID(uuidString: displayIdentifier),
            let currentSpace = rawValue["Current Space"] as? [String: Any]
        else { return nil }

        self.displayUUID = displayUUID
        self.spaceID = Self.spaceID(from: currentSpace["ManagedSpaceID"])
        self.type = Self.spaceType(from: currentSpace["type"])
        self.processIdentifier = Self.processIdentifier(from: currentSpace["pid"])
    }

    private static func spaceID(from value: Any?) -> CGSSpaceID? {
        guard let value = unsignedInteger(from: value) else { return nil }
        return CGSSpaceID(value)
    }

    private static func spaceType(from value: Any?) -> CGSSpaceType? {
        guard let value = unsignedInteger(from: value),
              value <= UInt64(UInt32.max)
        else { return nil }

        return CGSSpaceType(rawValue: UInt32(value))
    }

    private static func processIdentifier(from value: Any?) -> pid_t? {
        if let value = value as? pid_t {
            return value
        }

        if let value = value as? Int {
            return pid_t(value)
        }

        if let value = value as? NSNumber {
            return pid_t(value.int32Value)
        }

        return nil
    }

    private static func unsignedInteger(from value: Any?) -> UInt64? {
        if let value = value as? UInt32 {
            return UInt64(value)
        }

        if let value = value as? Int {
            guard value >= 0 else { return nil }
            return UInt64(value)
        }

        if let value = value as? UInt {
            return UInt64(value)
        }

        if let value = value as? NSNumber {
            guard value.int64Value >= 0 else { return nil }
            return value.uint64Value
        }

        return nil
    }
}
