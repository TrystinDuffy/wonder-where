import SwiftUI
import UIKit

struct TripCalendarShareFile: Identifiable {
    let id: UUID
    let url: URL

    static func prepare(trip: Trip, origin: Point?, at date: Date) async throws -> Self {
        try await Task.detached(priority: .userInitiated) {
            // Export a consistent copy without adapting allocations or changing saved progress.
            let projection = TripScheduler.project(trip: trip, liveOrigin: origin, now: date, adapt: false)
            let document = try TripCalendarExport.make(trip: trip, projection: projection, generatedAt: date)
            let manager = FileManager.default
            let root = manager.temporaryDirectory.appendingPathComponent("CompassDayCalendarExports", isDirectory: true)
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            // Keep recent files available to sharing extensions after the sheet closes.
            if let previous = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
                for directory in previous {
                    if let created = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate,
                       date.timeIntervalSince(created) > 7 * 24 * 60 * 60 {
                        try? manager.removeItem(at: directory)
                    }
                }
            }
            let id = UUID()
            let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(document.filename)
            do {
                try document.data.write(to: url, options: .atomic)
            } catch {
                try? manager.removeItem(at: directory)
                throw error
            }
            return Self(id: id, url: url)
        }.value
    }
}

struct TripCalendarShareSheet: UIViewControllerRepresentable {
    let file: TripCalendarShareFile
    var onCompletion: (String?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            Task { @MainActor in onCompletion(error?.localizedDescription) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
