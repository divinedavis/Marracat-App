import XCTest

/// Speed and memory on the paths shoppers wait on, added 2026-10-03 with
/// Apple's XCTMetric API. scripts/perf_gate.py fails the ship when a metric is
/// more than 1.5x the median of the last five passing ships
/// (scripts/perf_baseline.json). Simulator numbers catch regressions, not
/// real-world times; those come from MetricKit (Stores/MetricsReporter.swift)
/// and the Xcode Organizer (scripts/organizer_report.py).
final class PerformanceTests: XCTestCase {
    private let args = ["-OFFLINE_CATALOG", "-SKIP_SPLASH", "-CHECKOUT_STUB"]   // -OFFLINE_CATALOG keeps MeaningIndex off the 95 MB ML download

    /// Cold launch to the first frame a shopper can touch.
    func testLaunch() {
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: opts) {
            let app = XCUIApplication(); app.launchArguments = args
            app.launch()
        }
    }

    /// Launch until Home shows products: the catalog decode people wait through.
    func testLaunchToHomeProducts() {
        let app = XCUIApplication(); app.launchArguments = args
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: opts) {
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "productTile").firstMatch.waitForExistence(timeout: 30))
            app.terminate()
        }
    }

    /// Flinging Home, and the memory the app holds with the feed loaded.
    func testHomeScroll() {
        let app = XCUIApplication(); app.launchArguments = args
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "productTile").firstMatch.waitForExistence(timeout: 30))
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        opts.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTMemoryMetric(application: app)], options: opts) {
            app.swipeUp(velocity: .fast)
            stopMeasuring()
            app.swipeDown(velocity: .fast)
        }
    }

    /// Owner, build 132: a fling down Home about 1.75 s after it appeared
    /// froze for ~280 ms ("i want to do anything possible to remove that
    /// glitch as i scroll"). The cause was search's "Deals for you" being
    /// ranked on the main thread just after the whole catalog landed; that
    /// row and its warm-up are gone since 2026-10-12 (the Featured banner
    /// reads a dozen premier brands, no search), and this guards it. A
    /// shopper with history (two searches), a cold launch through the launch
    /// cover, a fling down Home as soon as it is up: the app's HitchProbe
    /// (-HITCH_PROBE) reports the main thread's hitch-time ratio and longest
    /// stall from the moment Home was shown, and when that was.
    ///
    /// No element queries between the launch and the read: each one makes the
    /// app snapshot its accessibility tree on the main thread, which is a
    /// stall of the test's own making.
    func testHomeFlingAfterLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG"]
        app.launch()
        for query in ["candle", "gold necklace"] {
            let field = app.storeSearchField()
            XCTAssertTrue(field.waitForExistence(timeout: 15))
            let input = app.descendants(matching: .any).matching(identifier: "searchInput").firstMatch
            // Setup, not the measurement: right after a cold launch (animations
            // on) the first tap can land before Home takes touches. Once, after
            // the full UI suite, it never opened search (2026-10-18).
            for _ in 0..<3 where !input.exists {
                field.tap()
                if input.waitForExistence(timeout: 5) { break }
            }
            XCTAssertTrue(input.exists, "search didn't open")
            input.typeText(query + "\n")
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "resultsHeader").firstMatch.waitForExistence(timeout: 10))
            app.buttons["tab.home"].tap()
        }
        sleep(1)
        app.terminate()

        // Today's splash already seen: the everyday launch, through the cover.
        let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        app.launchArguments = ["-CHECKOUT_STUB", "-OFFLINE_CATALOG", "-HITCH_PROBE", "-splash.lastShownDay", String(today)]
        let opts = XCTMeasureOptions(); opts.iterationCount = 3
        measure(metrics: [HomeFlingMetric()], options: opts) {
            app.launch()
            usleep(300_000)
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            for _ in 0..<3 {
                bottom.press(forDuration: 0.01, thenDragTo: top, withVelocity: .fast, thenHoldForDuration: 0)
                usleep(300_000)
            }
            sleep(3)
            let probe = app.descendants(matching: .any).matching(identifier: "hitchProbe").firstMatch
            XCTAssertTrue(probe.waitForExistence(timeout: 10), "the app's HitchProbe isn't there (-HITCH_PROBE)")
            HomeFlingMetric.readings.append((Date(), probe.label))
            app.terminate()
        }
    }
}

/// The numbers HitchProbe reported for the iteration that just ran, as
/// XCTMetric measurements, so scripts/perf_gate.py keeps a baseline of them
/// like any other metric.
final class HomeFlingMetric: NSObject, XCTMetric {
    /// Each iteration's reading with when it was taken: XCTest asks for the
    /// measurements of every iteration after the last one has run.
    static var readings: [(at: Date, label: String)] = []

    func copy(with zone: NSZone? = nil) -> Any { HomeFlingMetric() }

    func reportMeasurements(from startTime: XCTPerformanceMeasurementTimestamp,
                            to endTime: XCTPerformanceMeasurementTimestamp) throws -> [XCTPerformanceMeasurement] {
        let reading = Self.readings.last { $0.at >= startTime.date && $0.at <= endTime.date }?.label ?? ""
        var v: [String: Double] = [:]
        for part in reading.split(separator: ";") {
            let kv = part.split(separator: "=")
            if kv.count == 2, let d = Double(kv[1]) { v[String(kv[0])] = d }
        }
        guard let hitch = v["hitch"], let stall = v["stall"], let interactive = v["interactive"], interactive > 0 else {
            throw NSError(domain: "HomeFlingMetric", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unreadable HitchProbe reading: \(reading)"])
        }
        return [
            XCTPerformanceMeasurement(identifier: "com.marracat.home.hitchRatio", displayName: "Home fling hitch ratio",
                                      doubleValue: hitch, unitSymbol: "ms/s", polarity: .prefersSmaller),
            XCTPerformanceMeasurement(identifier: "com.marracat.home.longestStall", displayName: "Home longest main-thread stall",
                                      doubleValue: stall, unitSymbol: "ms", polarity: .prefersSmaller),
            XCTPerformanceMeasurement(identifier: "com.marracat.home.interactive", displayName: "Launch to interactive Home",
                                      doubleValue: interactive, unitSymbol: "ms", polarity: .prefersSmaller),
        ]
    }
}
