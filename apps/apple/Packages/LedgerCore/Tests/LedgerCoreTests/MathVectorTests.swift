import Foundation
import Testing
@testable import LedgerCore

struct DistributeFile: Decodable {
    struct Case: Decodable { var name: String; var total: Int; var weights: [String: Int]; var expect: [String: Int] }
    var cases: [Case]
}

struct TransfersFile: Decodable {
    struct T: Decodable { var from: String; var to: String; var amount: Int }
    struct Case: Decodable { var name: String; var balances: [String: Int]; var expect: [T] }
    var cases: [Case]
}

struct BalancesFile: Decodable {
    struct Line: Decodable { var member: String; var amount: Int }
    struct P: Decodable {
        var id: String; var amount: Int; var track: Bool; var `in`: [Line]; var out: [Line]
        var arrivals: [Line]?; var deleted: Bool?
    }
    struct Expect: Decodable {
        var balances: [String: Int]; var pendingOwned: [String: Int]; var pendingHeld: [String: Int]
        var transfers: [TransfersFile.T]
    }
    struct Case: Decodable { var name: String; var members: [String]; var payments: [P]; var expect: Expect }
    var cases: [Case]
}

@Test func distributeVectors() throws {
    let file = try JSONDecoder().decode(DistributeFile.self, from: vectors("distribute.json"))
    for c in file.cases {
        #expect(Balances.distribute(c.total, weights: c.weights) == c.expect, "\(c.name)")
    }
}

@Test func transferVectors() throws {
    let file = try JSONDecoder().decode(TransfersFile.self, from: vectors("transfers.json"))
    for c in file.cases {
        let got = Balances.transfers(c.balances)
        #expect(got == c.expect.map { Balances.Transfer(from: $0.from, to: $0.to, amount: $0.amount) }, "\(c.name)")
    }
}

@Test func balanceVectors() throws {
    let file = try JSONDecoder().decode(BalancesFile.self, from: vectors("balances.json"))
    for c in file.cases {
        var arrivals: [PaymentID: [Arrival]] = [:]
        let payments = c.payments.filter { $0.deleted != true }.map { p in
            arrivals[p.id] = (p.arrivals ?? []).enumerated().map {
                Arrival(id: "\(p.id)-\($0.offset)", payment: p.id, member: $0.element.member, amount: $0.element.amount, author: "x", at: "")
            }
            let side = { (l: [BalancesFile.Line]) in Payment.Side(mode: "exact", lines: l.map { Payment.Line(member: $0.member, amount: $0.amount) }) }
            return Payment(id: p.id, kind: .income, title: "t", date: "2026-01-01", amount: p.amount, track: p.track, in: side(p.in), out: side(p.out))
        }
        let s = Balances.summarize(members: c.members, payments: payments, arrivals: arrivals)
        #expect(s.balances == c.expect.balances, "\(c.name)")
        #expect(s.pendingOwned == c.expect.pendingOwned, "\(c.name)")
        #expect(s.pendingHeld == c.expect.pendingHeld, "\(c.name)")
        #expect(s.transfers == c.expect.transfers.map { .init(from: $0.from, to: $0.to, amount: $0.amount) }, "\(c.name)")
    }
}

@Test(arguments: [
    ("12,40", 1240), ("12.4", 1240), ("1.240,00", 124000), ("1,240.00", 124000), ("12", 1200),
    ("0,5", 50), ("1.240", 124000), ("12,", 1200),
])
func parseMoney(input: String, minor: Int) {
    #expect(Money.parse(input, currency: "EUR") == minor)
}

@Test func parseMoneyRejects() {
    for s in ["", "abc", "12abc", "1,2,3", "12,345,6", "-5", "1.2.3,45.6"] {
        #expect(Money.parse(s, currency: "EUR") == nil, "\(s)")
    }
    #expect(Money.parse("1500", currency: "JPY") == 1500)
}

@Test func percentWithRest() {
    let r = Splits.percent(100_000, basisPoints: ["a": 6000, "b": 3333], rest: "a")
    #expect(r == ["a": 66_670, "b": 33_330])
}
