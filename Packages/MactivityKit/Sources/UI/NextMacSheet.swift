import AppKit
import Core
import os
import SwiftUI

/// "Your next Mac" as a one-page PDF (D-181): the page as drawn on screen, into a PDF context, so
/// its text stays text.
@MainActor
enum NextMacPDF {
    private static let log = Logger(subsystem: "app.mactivity.ui", category: "next-mac")

    static func data(_ report: NextMacReport) -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: NextMacPage.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return nil
        }
        let renderer = ImageRenderer(content: NextMacPage(report: report))
        renderer.proposedSize = ProposedViewSize(NextMacPage.size)
        context.beginPDFPage(nil)
        Customization.shared.atStandardSize {
            renderer.render { _, draw in draw(context) }
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Asks where to save, writes the PDF, and shows it in Finder.
    static func save(_ report: NextMacReport, services: AppServices) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save PDF", bundle: .strings)
        panel.nameFieldStringValue = String(localized: "Your Next Mac.pdf", bundle: .strings, comment: "File name of the next-Mac report")
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        guard let pdf = data(report) else {
            services.show(toast: String(localized: "The report couldn't be made.", bundle: .strings))
            return
        }
        do {
            try pdf.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            log.error("Next Mac: write failed")
            services.show(toast: String(localized: "The report couldn't be saved there.", bundle: .strings))
        }
    }
}

/// The page on screen, with the span and Save PDF…: what you see is the PDF.
struct NextMacSheet: View {
    let services: AppServices
    @Bindable var model: NextMacModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Spacing.s) {
                Picker(String(localized: "Period", bundle: .strings), selection: $model.days) {
                    Text("7 days", bundle: .strings).tag(7)
                    Text("30 days", bundle: .strings).tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(String(localized: "Save PDF…", bundle: .strings)) {
                    if let report = model.report {
                        NextMacPDF.save(report, services: services)
                    }
                }
                .disabled(model.report == nil)
                Button(String(localized: "Done", bundle: .strings)) { model.isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    // Esc closes it too, as Return does: an information sheet has nothing to cancel (D-196).
                    .background {
                        Button("") { model.isPresented = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    }
            }
            .padding(Tokens.Spacing.m)
            Divider()
            ScrollView {
                Group {
                    if let report = model.report {
                        NextMacPage(report: report)
                            .clipShape(.rect(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    } else {
                        ProgressView().frame(width: NextMacPage.size.width, height: 300)
                    }
                }
                .padding(Tokens.Spacing.l)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(minWidth: 680, idealWidth: 700, minHeight: 460, idealHeight: 760, maxHeight: 860)
        .task(id: model.days) { await model.load(services) }
    }
}
