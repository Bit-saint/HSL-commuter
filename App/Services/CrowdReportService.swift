import CloudKit
import Foundation
import ETAEngine

/// "How full is it?" answers from riders, shared with everyone through the CloudKit
/// public database (no server to run). Reports carry only the trip, the level and the
/// time. Sharing needs the iCloud capability, which needs a paid Apple Developer account;
/// without it (CROWD_SHARING = NO) your own reports are still used on this phone.
@MainActor
final class CrowdReportService {
    static let recordType = "OccupancyReport"

    /// Build-time switch (Config/*.xcconfig → Info.plist).
    let sharingAvailable: Bool = (Bundle.main.object(forInfoDictionaryKey: "CrowdSharing") as? String)?.uppercased() == "YES"
    private lazy var database: CKDatabase? = sharingAvailable ? CKContainer.default().publicCloudDatabase : nil

    /// Your own recent reports, so they count even when offline or not sharing.
    private var local: [CrowdReport] = []
    private var cache: [String: (fetched: Date, reports: [CrowdReport])] = [:]

    func submit(tripKey: String, level: CrowdLevel, share: Bool) {
        let report = CrowdReport(tripKey: tripKey, level: level, time: Date())
        local.append(report)
        local.removeAll { Date().timeIntervalSince($0.time) > 3600 }
        guard share, let database else { return }
        let record = CKRecord(recordType: Self.recordType)
        record["tripKey"] = tripKey as CKRecordValue
        record["level"] = level.rawValue as CKRecordValue
        Task { _ = try? await database.save(record) }
    }

    /// Estimates for the given trips (cached for a minute).
    func estimates(for tripKeys: [String], now: Date = Date()) async -> [String: CrowdEstimate] {
        let keys = Array(Set(tripKeys))
        guard !keys.isEmpty else { return [:] }
        let stale = keys.filter { cache[$0].map { now.timeIntervalSince($0.fetched) > 60 } ?? true }
        if !stale.isEmpty, let database {
            let since = now.addingTimeInterval(-30 * 60)
            let predicate = NSPredicate(format: "tripKey IN %@ AND creationDate > %@", stale, since as NSDate)
            let query = CKQuery(recordType: Self.recordType, predicate: predicate)
            if let response = try? await database.records(matching: query, resultsLimit: 200) {
                var byTrip: [String: [CrowdReport]] = [:]
                for case let (_, .success(record)) in response.matchResults {
                    guard let key = record["tripKey"] as? String, let raw = record["level"] as? Int,
                          let level = CrowdLevel(rawValue: raw) else { continue }
                    byTrip[key, default: []].append(CrowdReport(tripKey: key, level: level,
                                                                time: record.creationDate ?? now))
                }
                for key in stale { cache[key] = (now, byTrip[key] ?? []) }
            }
        }
        var out: [String: CrowdEstimate] = [:]
        for key in keys {
            let reports = (cache[key]?.reports ?? []) + local.filter { $0.tripKey == key }
            if let e = CrowdOccupancy.estimate(reports, now: now) { out[key] = e }
        }
        return out
    }
}
