import Foundation
import Testing
@testable import CalSyncCore

private func ref(_ id: String) -> CalendarRef {
    CalendarRef(id: id, name: "Cal-\(id)", accountName: "Acct-\(id)")
}

/// Dedicated-destination shape: four distinct calendars.
private func validConfig() -> AppConfig {
    AppConfig(sides: [
        SyncSide(id: "company", source: ref("companySrc"), mirrorTo: ref("clientBusy")),
        SyncSide(id: "client", source: ref("clientSrc"), mirrorTo: ref("companyBusy")),
    ])
}

/// Two-calendar shape: A and B block each other directly, with no extra calendars.
/// Each side's destination is the other side's source.
private func directConfig() -> AppConfig {
    AppConfig(sides: [
        SyncSide(id: "company", source: ref("A"), mirrorTo: ref("B")),
        SyncSide(id: "client", source: ref("B"), mirrorTo: ref("A")),
    ])
}

@Suite("Config validation")
struct ConfigTests {

    @Test("a fully configured pair validates")
    func acceptsValid() {
        #expect(ConfigValidator.validate(validConfig()) == nil)
        #expect(validConfig().isConfigured)
    }

    @Test("a fresh install is not yet configured")
    func rejectsEmpty() {
        #expect(ConfigValidator.validate(AppConfig()) != nil)
        #expect(!AppConfig().isConfigured)
    }

    @Test("one configured side is not enough")
    func rejectsSingleSide() {
        var config = validConfig()
        config.sides = [config.sides[0]]
        #expect(ConfigValidator.validate(config) != nil)
    }

    // The common two-calendar setup. It looks like a loop but is not: the reader skips
    // events carrying our marker or our block title, so blocks never bounce back.
    @Test("two calendars blocking each other directly is allowed")
    func acceptsDirectMutualBlocking() {
        #expect(ConfigValidator.validate(directConfig()) == nil)
        #expect(directConfig().isConfigured)
    }

    @Test("one side's destination may be the other side's source")
    func acceptsDestinationEqualsOtherSource() {
        var config = validConfig()
        config.sides[0].mirrorTo = config.sides[1].source
        #expect(ConfigValidator.validate(config) == nil)
    }

    // Each side would see the other's blocks as orphans and delete them, every run.
    @Test("both sides writing into one calendar is rejected")
    func rejectsSharedDestination() {
        var config = validConfig()
        config.sides[1].mirrorTo = config.sides[0].mirrorTo
        #expect(ConfigValidator.validate(config)?.contains("same calendar") == true)
    }

    @Test("a side reading and writing the same calendar is rejected")
    func rejectsSelfMirror() {
        var config = validConfig()
        config.sides[0].mirrorTo = config.sides[0].source
        #expect(ConfigValidator.validate(config)?.contains("Busy copies") == true)
    }

    @Test("both sides reading the same calendar is rejected")
    func rejectsDuplicateSources() {
        var config = validConfig()
        config.sides[1].source = config.sides[0].source
        #expect(ConfigValidator.validate(config)?.contains("reading the same calendar") == true)
    }

    @Test("an unset calendar is reported")
    func rejectsEmptyIdentifier() {
        var config = validConfig()
        config.sides[0].source = CalendarRef(id: "  ", name: "", accountName: "")
        #expect(ConfigValidator.validate(config) != nil)
    }

    @Test("the busy title cannot be blank")
    func rejectsBlankTitle() {
        var config = validConfig()
        config.busyTitle = "   "
        #expect(ConfigValidator.validate(config) != nil)
    }

    @Test("window must be a sane number of days", arguments: [0, -5, 400])
    func rejectsBadWindow(days: Int) {
        var config = validConfig()
        config.windowDays = days
        #expect(ConfigValidator.validate(config) != nil)
    }

    @Test("threshold must be a fraction", arguments: [-0.1, 1.5])
    func rejectsBadThreshold(threshold: Double) {
        var config = validConfig()
        config.cancelThreshold = threshold
        #expect(ConfigValidator.validate(config) != nil)
    }

    @Test("sync interval must be at least a minute")
    func rejectsBadInterval() {
        var config = validConfig()
        config.syncIntervalMinutes = 0
        #expect(ConfigValidator.validate(config) != nil)
    }

    @Test("config survives a round trip through JSON")
    func codableRoundTrip() throws {
        let original = validConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("display label includes the account so same-named calendars are tellable apart")
    func displayLabel() {
        #expect(CalendarRef(id: "1", name: "Calendar", accountName: "Exchange").displayLabel
                == "Calendar (Exchange)")
        #expect(CalendarRef(id: "1", name: "Calendar", accountName: "").displayLabel == "Calendar")
    }
}
