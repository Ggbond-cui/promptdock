import Testing
@testable import PromptDockCore

@Test func versionIsSemver() {
    let parts = PromptDockCore.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
