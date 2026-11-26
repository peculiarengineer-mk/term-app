import SwiftUI

struct LicencesView: View {
    private struct Entry: Identifiable {
        let title: String
        let file: String
        var id: String { file }
    }

    private let entries = [
        Entry(title: "GNU General Public License v3", file: "GPLv3"),
        Entry(title: "libssh2, BSD-3-Clause", file: "libssh2"),
        Entry(title: "OpenSSL 3, Apache-2.0", file: "OpenSSL"),
        Entry(title: "SwiftTerm, MIT", file: "SwiftTerm"),
    ]

    var body: some View {
        Form {
            Section {
                Text("term-app is free software, licensed under the GNU General Public License version 3.")
                if let url = URL(string: "https://github.com/peculiarengineer-mk/term-app") {
                    Link("https://github.com/peculiarengineer-mk/term-app", destination: url)
                }
            }
            Section {
                ForEach(entries) { entry in
                    NavigationLink(entry.title) {
                        LicenceTextView(title: entry.title, file: entry.file)
                    }
                }
            }
        }
        .navigationTitle("Licences")
    }
}

private struct LicenceTextView: View {
    let title: String
    let file: String
    @State private var text: String?
    @State private var isLoaded = false

    var body: some View {
        ScrollView {
            if let text {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else if isLoaded {
                Text("Licence text missing")
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: file) {
            guard !isLoaded else { return }
            let loaded = await Task.detached(priority: .userInitiated) { [file] () -> String? in
                guard let url = Bundle.main.url(forResource: file, withExtension: "txt") else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            }.value
            text = loaded
            isLoaded = true
        }
    }
}
