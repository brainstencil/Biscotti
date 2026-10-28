import DataStore
import Testing

@Suite("NameReplacement")
struct NameReplacementTests {
    private func replace(_ old: String, _ new: String, _ text: String) -> String {
        NameReplacement.apply(old: old, new: new, to: text)
    }

    @Test("Replaces whole-word occurrences, including possessives and markdown")
    func wholeWords() {
        #expect(replace("Steven", "Stephen", "Steven said hi.") == "Stephen said hi.")
        #expect(replace("Steven", "Stephen", "Steven's plan") == "Stephen's plan")
        #expect(replace("Steven", "Stephen", "**Steven** and (Steven)") == "**Stephen** and (Stephen)")
        #expect(replace("Steven", "Stephen", "- Steven: ship it") == "- Stephen: ship it")
    }

    @Test("Leaves partial words and different casing alone")
    func partialWords() {
        #expect(replace("Steven", "Stephen", "Stevenson and SteveN") == "Stevenson and SteveN")
        #expect(replace("Steven", "Stephen", "steven") == "steven")
        #expect(replace("Paul", "Pablo", "Paul_1 and 2Paul") == "Paul_1 and 2Paul")
    }

    @Test("An expansion does not touch occurrences already inside the new name")
    func expansion() {
        #expect(
            replace("Paul", "Paul Kowalski", "Paul and Paul Kowalski met.")
                == "Paul Kowalski and Paul Kowalski met."
        )
        #expect(NameReplacement.count(of: "Paul", replacingWith: "Paul Kowalski", in: "Paul Kowalski") == 0)
    }

    @Test("Same old and new name is a no-op")
    func noOp() {
        #expect(replace("Paul", "Paul", "Paul said") == "Paul said")
        #expect(NameReplacement.count(of: "Paul", replacingWith: "Paul", in: "Paul said") == 0)
        #expect(NameReplacement.count(of: "", replacingWith: "Paul", in: "anything") == 0)
    }

    @Test("count matches the number of occurrences apply changes")
    func countMatchesApply() {
        struct Case {
            let old, new, text: String
            let expected: Int
        }
        let cases = [
            Case(old: "Steven", new: "Stephen", text: "Steven, Steven and Stevenson", expected: 2),
            Case(old: "Paul", new: "Paul Kowalski", text: "Paul, Paul Kowalski, Paul's", expected: 2),
            Case(old: "Ann", new: "Anne", text: "No match here", expected: 0)
        ]
        for item in cases {
            #expect(NameReplacement.count(of: item.old, replacingWith: item.new, in: item.text) == item.expected)
            let applied = NameReplacement.apply(old: item.old, new: item.new, to: item.text)
            #expect(NameReplacement.count(of: item.old, replacingWith: item.new, in: applied) == 0)
        }
    }

    @Test("Word boundaries are Unicode-aware")
    func unicode() {
        #expect(replace("José", "Josefina", "José and Joséa") == "Josefina and Joséa")
        #expect(replace("Lee", "Li", "éLee Lee") == "éLee Li")
    }
}

@Suite("NameReplacement -- protecting")
struct NameReplacementProtectingTests {
    @Test("Protected names are left intact, and a protected name equal to old is ignored")
    func protecting() {
        #expect(NameReplacement.apply(
            old: "Paul", new: "Pablo", to: "Paul and Paul Kowalski", protecting: ["Paul Kowalski"]
        ) == "Pablo and Paul Kowalski")
        #expect(NameReplacement.count(
            of: "Paul", replacingWith: "Pablo", in: "Paul", protecting: ["Paul"]
        ) == 1)
    }
}
