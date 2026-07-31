import CoreGraphics

protocol ScrollEventAccessProviding: AnyObject {
    func preflight() -> Bool
    @discardableResult func request() -> Bool
}

final class CoreGraphicsScrollEventAccess: ScrollEventAccessProviding {
    func preflight() -> Bool {
        CGPreflightPostEventAccess()
    }

    @discardableResult
    func request() -> Bool {
        CGRequestPostEventAccess()
    }
}

protocol ScrollEventPosting: AnyObject {
    func postPixelScroll(at location: CGPoint, deltaY: Int32) throws
}

enum ScrollEventPostingError: Error, Equatable {
    case eventCreationFailed
}

final class CoreGraphicsScrollEventPoster: ScrollEventPosting {
    func postPixelScroll(at location: CGPoint, deltaY: Int32) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ) else {
            throw ScrollEventPostingError.eventCreationFailed
        }
        event.location = location
        event.post(tap: .cghidEventTap)
    }
}
