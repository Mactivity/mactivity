import Core
import SwiftUI

/// Per-app volume (spec 5.7, M10): the apps playing audio, each with mute, a level, an output device, and
/// reset. Settings are remembered per app. Experimental and off by default (Settings → General).
struct VolumeView: View {
    let services: AppServices

    @State private var model: PerAppAudioModel

    init(services: AppServices) {
        self.init(services: services, model: PerAppAudioModel())
    }

    /// `model` already loaded: render tests.
    init(services: AppServices, model: PerAppAudioModel) {
        self.services = services
        _model = State(initialValue: model)
    }

    var body: some View {
        Form {
            if model.needsPermission {
                Section {
                    AudioPermissionNote()
                }
            } else if let message = model.failureMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if model.rows.isEmpty {
                    Text("No app is playing audio.", bundle: .strings)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    AudioAppRow(
                        row: row, identity: PerAppAudioModel.identity(for: row.client, in: services.metrics.snapshot),
                        devices: model.devices, model: model
                    )
                }
            } header: {
                Text("Apps playing audio", bundle: .strings)
            } footer: {
                Text(
                    """
                    Experimental. Level, mute, and output are remembered per app and come back whenever it plays. \
                    An app at 100% on the system default plays untouched; Reset hands it back and forgets it.
                    """,
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.poll { services.audio } }
    }
}
