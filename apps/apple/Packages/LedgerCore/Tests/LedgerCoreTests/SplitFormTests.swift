import Foundation
import Testing
@testable import LedgerCore

private let members = ["initech", "globex", "acme"]

@Test func receivedAndOwnedLikeTheExample() {
    // 130.000 arrive: Initech 90.000, Acme 40.000, Globex nothing (only empty field → rest = 0).
    let received = SplitForm(text: ["initech": "90.000", "acme": "40.000"])
    let r = received.resolve(amount: 13_000_000, members: members, currency: "EUR", fallback: .all("initech"))
    #expect(r.amounts == ["initech": 9_000_000, "acme": 4_000_000, "globex": 0])
    #expect(r.restMember == "globex")

    // Belongs: Globex 15 %, Acme 20.000, Initech the rest.
    let owned = SplitForm(text: ["globex": "15%", "acme": "20.000"])
    let o = owned.resolve(amount: 13_000_000, members: members, currency: "EUR", fallback: .copy(r.amounts!))
    #expect(o.amounts == ["globex": 1_950_000, "acme": 2_000_000, "initech": 9_050_000])
    #expect(o.restMember == "initech")

    let lines = SplitForm.lines(o.amounts!, order: members, form: owned, resolution: o, currency: "EUR")
    #expect(lines == [.init(member: "initech", amount: 9_050_000, rest: true), .init(member: "globex", amount: 1_950_000, value: 1500), .init(member: "acme", amount: 2_000_000)])

    // Reopening gives the same inputs back.
    let side = Payment.Side(mode: "mixed", lines: lines)
    let back = SplitForm(side: side, currency: "EUR")
    #expect(back.rest == "initech")
    #expect(back.text == ["globex": "15%", "acme": Money.bare(2_000_000, currency: "EUR")])
    #expect(back.resolve(amount: 13_000_000, members: members, currency: "EUR", fallback: .none).amounts == o.amounts)
}

@Test func fallbacks() {
    let empty = SplitForm()
    #expect(empty.resolve(amount: 900, members: members, currency: "EUR", fallback: .all("initech")).amounts == ["initech": 900, "globex": 0, "acme": 0])
    #expect(empty.resolve(amount: 900, members: members, currency: "EUR", fallback: .equal(members)).amounts == ["initech": 300, "globex": 300, "acme": 300])
    #expect(empty.resolve(amount: 900, members: members, currency: "EUR", fallback: .copy(["acme": 900])).amounts == ["acme": 900, "initech": 0, "globex": 0])
}

@Test func leftoverAndTooMuch() {
    // Two empty fields and no explicit rest: 500 still to distribute.
    var f = SplitForm(text: ["initech": "4"])
    var r = f.resolve(amount: 900, members: members, currency: "EUR", fallback: .none)
    #expect(r.amounts == nil)
    #expect(r.leftover == 500)
    f.rest = "acme"
    r = f.resolve(amount: 900, members: members, currency: "EUR", fallback: .none)
    #expect(r.amounts == ["initech": 400, "globex": 0, "acme": 500])

    let over = SplitForm(text: ["initech": "10", "globex": "5"])
    let o = over.resolve(amount: 900, members: members, currency: "EUR", fallback: .none)
    #expect(o.amounts == nil)
    #expect(o.leftover == -600)
}

@Test func percentRoundingIsAbsorbed() {
    let f = SplitForm(text: ["initech": "50%", "globex": "50%", "acme": "0"])
    #expect(f.resolve(amount: 101, members: members, currency: "EUR", fallback: .none).amounts == ["initech": 50, "globex": 51, "acme": 0])
    let thirds = SplitForm(text: ["initech": "33,34%", "globex": "33,33%", "acme": "33,33%"])
    #expect(thirds.resolve(amount: 100, members: members, currency: "EUR", fallback: .none).amounts?.values.reduce(0, +) == 100)
}

@Test func invalidInput() {
    let f = SplitForm(text: ["initech": "abc"])
    #expect(f.resolve(amount: 100, members: members, currency: "EUR", fallback: .none).invalid == ["initech"])
    #expect(SplitForm.parse("120%", currency: "EUR") == .invalid)
}
