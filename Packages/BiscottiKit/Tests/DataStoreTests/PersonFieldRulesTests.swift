import DataStore
import Testing

@Suite("PersonFieldRules")
struct PersonFieldRulesTests {
    @Test("normalizeName trims and collapses whitespace, keeping casing")
    func normalizeName() {
        #expect(PersonFieldRules.normalizeName("  Paul   Kowalski \n") == "Paul Kowalski")
        #expect(PersonFieldRules.normalizeName("Ann\t\tMarie\nLee") == "Ann Marie Lee")
        #expect(PersonFieldRules.normalizeName("deLaCruz") == "deLaCruz")
        #expect(PersonFieldRules.normalizeName(" \n\t ").isEmpty)
    }

    @Test("validateName rejects empty and over-long names")
    func validateName() {
        #expect(PersonFieldRules.validateName("") == .emptyName)
        #expect(PersonFieldRules.validateName(String(repeating: "a", count: 120)) == nil)
        #expect(PersonFieldRules.validateName(String(repeating: "a", count: 121)) == .nameTooLong)
    }

    @Test("normalizeEmail trims and lowercases; blank means no email")
    func normalizeEmail() {
        #expect(PersonFieldRules.normalizeEmail("  Paul@ACME.com ") == "paul@acme.com")
        #expect(PersonFieldRules.normalizeEmail("   ") == nil)
        #expect(PersonFieldRules.normalizeEmail("") == nil)
        #expect(PersonFieldRules.normalizeEmail(nil) == nil)
    }

    @Test("validateEmail accepts one @ with non-empty sides and no whitespace")
    func validateEmail() {
        #expect(PersonFieldRules.validateEmail(nil) == nil)
        #expect(PersonFieldRules.validateEmail("a@b") == nil)
        #expect(PersonFieldRules.validateEmail("paul@acme.co.uk") == nil)
        for bad in ["ab", "a@@b", "@b", "a@", "a b@c", "a@b@c"] {
            #expect(PersonFieldRules.validateEmail(bad) == .invalidEmail, "\(bad)")
        }
    }

    @Test("namesCollide ignores case only")
    func namesCollide() {
        #expect(PersonFieldRules.namesCollide("Steven", "steven"))
        #expect(PersonFieldRules.namesCollide("PAUL KOWALSKI", "Paul Kowalski"))
        #expect(!PersonFieldRules.namesCollide("Steven", "Stephen"))
    }
}
