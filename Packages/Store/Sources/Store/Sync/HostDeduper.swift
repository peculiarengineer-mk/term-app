import Foundation
import SwiftData

/// Collapses `Host` records that share an `id` (possible after CloudKit merges) into one.
///
/// - The survivor of a group is the copy with the lowest `copyID` (compared by `uuidString`), so
///   every device keeps the same record.
/// - The "newest" copy has the highest `updatedAt` truncated to whole milliseconds; among copies
///   tied at that value, the lowest `copyID`.
/// - If the newest copy is not the survivor and its truncated `updatedAt` is strictly greater than
///   the survivor's, every field except `id` and `copyID` is copied from it into the survivor
///   (`updatedAt` verbatim, no `touch()`).
/// - All other copies are deleted and the context is saved once.
/// Records with distinct ids are never touched.
public enum HostDeduper {
    /// Returns the number of records deleted.
    @discardableResult
    public static func dedupe(in context: ModelContext) throws -> Int {
        let all = try context.fetch(FetchDescriptor<Host>())
        let groups = Dictionary(grouping: all, by: \.id)
        var deleted = 0
        for (_, group) in groups where group.count > 1 {
            let byCopy = group.sorted { $0.copyID.uuidString < $1.copyID.uuidString }
            let survivor = byCopy[0]
            var newest = byCopy[0]
            for h in byCopy.dropFirst() where ms(h.updatedAt) > ms(newest.updatedAt) {
                newest = h
            }
            if newest !== survivor && ms(newest.updatedAt) > ms(survivor.updatedAt) {
                survivor.label = newest.label
                survivor.hostname = newest.hostname
                survivor.port = newest.port
                survivor.username = newest.username
                survivor.keyID = newest.keyID
                survivor.authMethod = newest.authMethod
                survivor.tmuxCommand = newest.tmuxCommand
                survivor.source = newest.source
                survivor.tags = newest.tags
                survivor.createdAt = newest.createdAt
                survivor.updatedAt = newest.updatedAt
            }
            for dup in byCopy.dropFirst() {
                context.delete(dup)
                deleted += 1
            }
        }
        if deleted > 0 { try context.save() }
        return deleted
    }

    private static func ms(_ d: Date) -> Double { (d.timeIntervalSinceReferenceDate * 1000).rounded(.down) }
}
