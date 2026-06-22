//
//  CrossSourceSettingsView.swift
//  Aidoku (iOS)
//
//  Settings for the cross-source newer-chapter check.
//

import AidokuRunner
import SwiftUI

struct CrossSourceSettingsView: View {
    @StateObject private var enabled = UserDefaultsBool(key: "CrossSource.enabled", defaultValue: true)
    @State private var checking = false

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("CROSS_SOURCE_ENABLED"), isOn: $enabled.value)
            } footer: {
                Text(NSLocalizedString("CROSS_SOURCE_ENABLED_TEXT"))
            }

            Section {
                Button {
                    checking = true
                    Task {
                        await CrossSourceChecker.shared.checkEntireLibrary(force: true)
                        checking = false
                    }
                } label: {
                    HStack {
                        Text(NSLocalizedString("CHECK_NOW"))
                        Spacer()
                        if checking {
                            ProgressView()
                        }
                    }
                }
                .disabled(checking || !enabled.value)

                NavigationLink(NSLocalizedString("EXCLUDED_SOURCES")) {
                    ExcludedSourcesView()
                }
            }
        }
        .navigationTitle(NSLocalizedString("CROSS_SOURCE_CHECK"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ExcludedSourcesView: View {
    @State private var excluded: Set<String>
    @State private var searchText = ""

    private let sources: [AidokuRunner.Source]

    init() {
        self.sources = SourceManager.shared.sources.filter { $0.key != LocalSourceRunner.sourceKey }
        self._excluded = State(
            initialValue: Set(UserDefaults.standard.stringArray(forKey: "CrossSource.excludedSources") ?? [])
        )
    }

    private var filteredSources: [AidokuRunner.Source] {
        if searchText.isEmpty {
            return sources
        }
        return sources.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filteredSources, id: \.key) { source in
                Button {
                    toggle(source.key)
                } label: {
                    HStack {
                        Text(source.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if excluded.contains(source.key) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText)
        .navigationTitle(NSLocalizedString("EXCLUDED_SOURCES"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ key: String) {
        if excluded.contains(key) {
            excluded.remove(key)
        } else {
            excluded.insert(key)
        }
        UserDefaults.standard.set(Array(excluded), forKey: "CrossSource.excludedSources")
    }
}
