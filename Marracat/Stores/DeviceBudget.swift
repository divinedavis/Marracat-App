import Foundation

/// Whether this is a good moment for work nobody is waiting on (2026-10-18):
/// not in Low Power Mode, not hot. Prefetching the next launch's images can
/// wait for a phone that's cool and charged; the shopper never sees it skip.
enum DeviceBudget {
    static var allowsOptionalWork: Bool {
        allowsOptionalWork(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                           thermal: ProcessInfo.processInfo.thermalState)
    }

    static func allowsOptionalWork(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        !lowPower && thermal != .serious && thermal != .critical
    }
}
