import Combine
import XCTest
@testable import BridgeApp

final class ControllerInputModelTests: XCTestCase {
    @MainActor func testHiddenWindowStoresInputWithoutPublishingAndRestoresLatest() {
        let input = ControllerInputModel()
        var changes = 0
        let subscription = input.objectWillChange.sink { changes += 1 }
        let observer = UUID()
        let pressed = ControllerInputSnapshot(buttons: 1)
        input.receive(pressed)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(input.snapshot, ControllerInputSnapshot())
        input.setVisible(true, observer: observer)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(input.snapshot, pressed)
        input.setVisible(false, observer: observer)
        input.receive(ControllerInputSnapshot())
        XCTAssertEqual(changes, 1)
        input.setVisible(true, observer: observer)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(input.snapshot, ControllerInputSnapshot())
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testIdenticalReportsDoNotPublishAndEveryButtonEdgeBypassesDisplayThrottle() {
        let input = ControllerInputModel()
        let observer = UUID()
        input.setVisible(true, observer: observer)
        var received: [UInt64] = []
        let subscription = input.$snapshot.dropFirst().sink { received.append($0.buttons) }
        for bit in 0..<21 {
            let pressed = ControllerInputSnapshot(buttons: UInt64(1) << bit)
            input.receive(pressed)
            input.receive(pressed)
            input.receive(ControllerInputSnapshot())
            input.receive(ControllerInputSnapshot())
        }
        XCTAssertEqual(received, (0..<21).flatMap { [UInt64(1) << $0, 0] })
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testVisibilityOwnersAndHiddenDisconnectDoNotLeaveStaleInput() {
        let input = ControllerInputModel()
        let first = UUID(), second = UUID()
        input.setVisible(true, observer: first)
        input.setVisible(true, observer: second)
        input.setVisible(false, observer: first)
        XCTAssertTrue(input.isVisible)
        input.receive(ControllerInputSnapshot(buttons: 1))
        XCTAssertEqual(input.snapshot.buttons, 1)
        input.setVisible(false, observer: second)
        var changes = 0
        let subscription = input.objectWillChange.sink { changes += 1 }
        input.clear()
        XCTAssertEqual(changes, 0)
        input.setVisible(true, observer: first)
        XCTAssertEqual(input.snapshot, ControllerInputSnapshot())
        XCTAssertEqual(changes, 1)
        input.clear()
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testInputPresentationDoesNotInvalidateRuntimeModel() {
        let bridge = BridgeModel.shared
        var changes = 0
        let subscription = bridge.objectWillChange.sink { changes += 1 }
        let observer = UUID()
        bridge.input.setVisible(true, observer: observer)
        bridge.input.receive(ControllerInputSnapshot(buttons: 1))
        bridge.input.receive(ControllerInputSnapshot())
        bridge.input.clear()
        bridge.input.setVisible(false, observer: observer)
        XCTAssertEqual(changes, 0)
        withExtendedLifetime(subscription) {}
    }
}
