import SwiftUI

/// Small bundled documents remain readable without a network connection.
struct AppInformationView: View {
    let title: String
    private let blocks: [String]

    init(title: String, resource: String) {
        self.title = title
        let text = Bundle.main.url(forResource: resource, withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        blocks = (text ?? "This page could not be loaded. Contact trystinduffy@gmail.com for help.")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    if block.hasPrefix("# ") {
                        Text(String(block.dropFirst(2))).font(.title.bold())
                            .accessibilityAddTraits(.isHeader)
                    } else if block.hasPrefix("## ") {
                        Text(String(block.dropFirst(3))).font(.title3.bold())
                            .padding(.top, 8).accessibilityAddTraits(.isHeader)
                    } else {
                        Text(LocalizedStringKey(block)).textSelection(.enabled)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("app-information-document")
    }
}
