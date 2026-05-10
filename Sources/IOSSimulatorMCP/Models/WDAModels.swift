import Foundation

// MARK: - Generic WDA Response envelope

struct WDAResponse<T: Decodable>: Decodable {
    let value: T?
    let sessionId: String?
}

struct WDASessionValue: Decodable {
    let sessionId: String
    let capabilities: WDACapabilities?
}

struct WDACapabilities: Decodable {
    let bundleId: String?
    let deviceName: String?
    let platformVersion: String?
}

struct WDAStatus: Decodable {
    let ready: Bool?
    let message: String?
}

// MARK: - Session create request

struct WDACreateSessionRequest: Encodable {
    let capabilities: WDASessionCapabilities

    struct WDASessionCapabilities: Encodable {
        let firstMatch: [[String: String]]
        let alwaysMatch: WDAAlwaysMatch

        struct WDAAlwaysMatch: Encodable {
            var bundleId: String?
            var shouldWaitForQuiescence: Bool = false

            enum CodingKeys: String, CodingKey {
                case bundleId
                case shouldWaitForQuiescence = "wda:shouldWaitForQuiescence"
            }
        }
    }

    static func make(bundleId: String? = nil) -> WDACreateSessionRequest {
        WDACreateSessionRequest(
            capabilities: .init(
                firstMatch: [[:]],
                alwaysMatch: .init(bundleId: bundleId, shouldWaitForQuiescence: false)
            )
        )
    }
}

// MARK: - W3C Actions (tap, swipe, long press)

struct WDAActionsRequest: Encodable {
    let actions: [WDAAction]

    struct WDAAction: Encodable {
        let type: String
        let id: String
        let parameters: WDAPointerParameters
        let actions: [WDAActionStep]
    }

    struct WDAPointerParameters: Encodable {
        let pointerType: String
    }

    struct WDAActionStep: Encodable {
        let type: String
        var duration: Int?
        var x: Double?
        var y: Double?
        var button: Int?
    }

    static func tap(x: Double, y: Double) -> WDAActionsRequest {
        WDAActionsRequest(actions: [
            WDAAction(type: "pointer", id: "finger1",
                      parameters: WDAPointerParameters(pointerType: "touch"),
                      actions: [
                          WDAActionStep(type: "pointerMove", duration: 0, x: x, y: y),
                          WDAActionStep(type: "pointerDown", button: 0),
                          WDAActionStep(type: "pause", duration: 100),
                          WDAActionStep(type: "pointerUp", button: 0),
                      ])
        ])
    }

    static func longPress(x: Double, y: Double, durationMs: Int) -> WDAActionsRequest {
        WDAActionsRequest(actions: [
            WDAAction(type: "pointer", id: "finger1",
                      parameters: WDAPointerParameters(pointerType: "touch"),
                      actions: [
                          WDAActionStep(type: "pointerMove", duration: 0, x: x, y: y),
                          WDAActionStep(type: "pointerDown", button: 0),
                          WDAActionStep(type: "pause", duration: durationMs),
                          WDAActionStep(type: "pointerUp", button: 0),
                      ])
        ])
    }

    static func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int = 500) -> WDAActionsRequest {
        WDAActionsRequest(actions: [
            WDAAction(type: "pointer", id: "finger1",
                      parameters: WDAPointerParameters(pointerType: "touch"),
                      actions: [
                          WDAActionStep(type: "pointerMove", duration: 0, x: fromX, y: fromY),
                          WDAActionStep(type: "pointerDown", button: 0),
                          WDAActionStep(type: "pointerMove", duration: durationMs, x: toX, y: toY),
                          WDAActionStep(type: "pointerUp", button: 0),
                      ])
        ])
    }
}

// MARK: - Keys (type text)

struct WDAKeysRequest: Encodable {
    let value: [String]

    static func make(_ text: String) -> WDAKeysRequest {
        WDAKeysRequest(value: text.map { String($0) })
    }
}

// MARK: - Button press

struct WDAButtonRequest: Encodable {
    let name: String
}

// MARK: - Coordinate describe

struct WDACoordinateRequest: Encodable {
    let x: Double
    let y: Double
}

// MARK: - App lifecycle

struct WDAActivateAppRequest: Encodable {
    let bundleId: String
}

struct WDATerminateAppRequest: Encodable {
    let bundleId: String
}
