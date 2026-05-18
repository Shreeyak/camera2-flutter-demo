import Testing

@testable import CameraKit

@Suite struct SessionStateMachineTests {

    // Hand-enumerated because SessionState is not CaseIterable (public
    // API; we don't add conformance just for tests).
    static let allStates: [SessionState] = [
        .closed, .opening, .streaming, .paused, .recovering, .error, .interrupted,
    ]

    // Expected sets duplicated here on purpose: if production map drifts
    // from the spec, these tests catch it.
    static let expectedCommandMap: [SessionState: Set<SessionState>] = [
        .closed: [.opening, .streaming, .paused],
        .opening: [.streaming, .closed, .error],
        .streaming: [.paused, .closed],
        .paused: [.streaming, .closed],
        .recovering: [.closed],
        .error: [.closed],
        .interrupted: [.closed],
    ]

    static let expectedEventMap: [SessionState: Set<SessionState>] = [
        .opening: [.error, .interrupted],
        .streaming: [.recovering, .error, .paused, .interrupted],
        .paused: [.streaming, .recovering, .error, .interrupted],
        .recovering: [.streaming, .error],
        .interrupted: [.streaming, .error],
        .closed: [.error],
        .error: [],
    ]

    @Test("initial current is .closed")
    func initialIsClosed() {
        let sm = SessionStateMachine()
        #expect(sm.current == .closed)
    }

    @Test("transition mutates current regardless of classification")
    func transitionMutatesCurrent() {
        var sm = SessionStateMachine()
        sm.transition(to: .streaming, kind: .command)
        #expect(sm.current == .streaming)
    }

    @Test("expected transition returns .expected and updates current")
    func expectedTransition() {
        var sm = SessionStateMachine()
        let cls = sm.transition(to: .streaming, kind: .command)
        #expect(cls == .expected)
        #expect(sm.current == .streaming)
    }

    @Test("off-map transition returns .offMap but still updates current")
    func offMapStillUpdates() {
        var sm = SessionStateMachine()
        sm._setCurrentForTest(.recovering)
        // recovering → opening is not in either map.
        let cls = sm.transition(to: .opening, kind: .command)
        #expect(cls == .offMap)
        #expect(sm.current == .opening)
    }

    @Test("self-transition is always expected, both kinds")
    func selfTransitionExpected() {
        for state in Self.allStates {
            #expect(
                SessionStateMachine.classify(from: state, to: state, kind: .command)
                    == .expected
            )
            #expect(
                SessionStateMachine.classify(from: state, to: state, kind: .event)
                    == .expected
            )
        }
    }

    @Test(
        "command map: every (from, to) classifies correctly",
        arguments: Self.allStates, Self.allStates
    )
    func commandMapClassification(from: SessionState, to: SessionState) {
        let expected: SessionStateMachine.Classification =
            from == to || Self.expectedCommandMap[from]?.contains(to) == true
            ? .expected : .offMap
        let actual = SessionStateMachine.classify(from: from, to: to, kind: .command)
        #expect(
            actual == expected,
            "command \(from) → \(to): expected \(expected), got \(actual)")
    }

    @Test(
        "event map: every (from, to) classifies correctly",
        arguments: Self.allStates, Self.allStates
    )
    func eventMapClassification(from: SessionState, to: SessionState) {
        let expected: SessionStateMachine.Classification =
            from == to || Self.expectedEventMap[from]?.contains(to) == true
            ? .expected : .offMap
        let actual = SessionStateMachine.classify(from: from, to: to, kind: .event)
        #expect(
            actual == expected,
            "event \(from) → \(to): expected \(expected), got \(actual)")
    }
}
