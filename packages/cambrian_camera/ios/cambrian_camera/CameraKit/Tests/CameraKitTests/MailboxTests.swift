import Testing

@testable import CameraKit

@Suite struct MailboxTests {

    @Test("latest is nil before first store")
    func latestNilBeforeStore() {
        let mb = Mailbox<Int>()
        #expect(mb.latest == nil)
    }

    @Test("initial value via init is stored")
    func initialValue() {
        let mb = Mailbox<Int>(7)
        #expect(mb.latest == 7)
    }

    @Test("store then read round-trips")
    func storeThenRead() {
        let mb = Mailbox<Int>()
        mb.store(42)
        #expect(mb.latest == 42)
    }

    @Test("last write wins")
    func lastWriteWins() {
        let mb = Mailbox<Int>()
        mb.store(1)
        mb.store(2)
        mb.store(3)
        #expect(mb.latest == 3)
    }

    @Test("store nil clears")
    func storeNilClears() {
        let mb = Mailbox<Int>()
        mb.store(42)
        mb.store(nil)
        #expect(mb.latest == nil)
    }

    @Test("reference type semantics — two readers see the same updates")
    func referenceTypeSemantics() {
        let mb = Mailbox<Int>()
        let aliased = mb
        mb.store(99)
        #expect(aliased.latest == 99)
    }

    @Test("Sendable witness — usable across Task boundary")
    func sendableWitness() async {
        let mb = Mailbox<Int>(10)
        let result = await Task.detached { mb.latest }.value
        #expect(result == 10)
    }
}
