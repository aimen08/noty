import Foundation

/// Checks that ☐/☑ task markers and Markdown task syntax convert on every line,
/// in both directions.
enum TaskMarkerTests {
    typealias Check = (Bool, String) -> Void

    static func run(check: Check) {
        testEveryTaskLineConverts(check)
        testMidLineMarkerIsNotATask(check)
        testTaskRoundTrip(check)
    }

    private static func testEveryTaskLineConverts(_ check: Check) {
        let markdown = """
        - [ ] first
        - [x] second
          - [ ] indented third
        not a task
        """
        let expected = """
        \(Tasks.openPrefix)first
        \(Tasks.donePrefix)second
          \(Tasks.openPrefix)indented third
        not a task
        """
        check(Tasks.fromMarkdown(markdown) == expected,
              "every markdown task line must convert, not only the first")
    }

    private static func testMidLineMarkerIsNotATask(_ check: Check) {
        let body = "the \(Tasks.open) glyph used mid-sentence"
        check(Tasks.toMarkdown(body) == body,
              "a marker in the middle of a line is text, not a task")
    }

    private static func testTaskRoundTrip(_ check: Check) {
        let body = """
        \(Tasks.openPrefix)open
        \(Tasks.donePrefix)done
        a plain line
          \(Tasks.openPrefix)nested
        """
        check(Tasks.fromMarkdown(Tasks.toMarkdown(body)) == body,
              "tasks must survive a markdown round trip unchanged")
    }
}
