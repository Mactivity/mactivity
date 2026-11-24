import SwiftUI

/// Settings → Customize (D-240): the live CPU and Memory cards on top, as the main window draws
/// them, then the choices that change them.
struct CustomizeSettings: View {
    let metrics: LiveMetrics
    @Bindable private var style = Customization.shared

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: Tokens.Spacing.gridGutter) {
                    HeadlineCard(.cpu, metrics: metrics, compact: true)
                    HeadlineCard(.memory, metrics: metrics, compact: true)
                }
                .padding(Tokens.Spacing.xs)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Preview", bundle: .strings, comment: "Customize: the sample cards"))
            } footer: {
                Text("The cards change as you choose, and so does every window.", bundle: .strings)
            }
            Section {
                ChoiceRow(title: String(localized: "Colors", bundle: .strings, comment: "Customize: the metrics' color palette")) {
                    ForEach(MetricPalette.allCases) { palette in
                        ChoiceButton(title: palette.title, isOn: style.palette == palette) {
                            style.palette = palette
                        } sample: {
                            HStack(spacing: 3) {
                                ForEach(MetricTab.allCases, id: \.self) { metric in
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(palette.color(metric).gradient)
                                        .frame(width: 10, height: 20)
                                }
                            }
                        }
                    }
                }
                ChoiceRow(title: String(localized: "Figures", bundle: .strings, comment: "Customize: the big figures' typeface")) {
                    ForEach(FigureTypeface.allCases) { typeface in
                        ChoiceButton(title: typeface.title, isOn: style.typeface == typeface) {
                            style.typeface = typeface
                        } sample: {
                            FigureSample(typeface: typeface, weight: style.fontWeight)
                        }
                    }
                }
                LabeledContent {
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text(verbatim: "A").font(.system(size: 13, weight: .light))
                        Slider(
                            value: Binding(get: { Double(style.weight) }, set: { style.weight = Int($0.rounded()) }),
                            in: 0 ... Double(FigureTypeface.weights.count - 1),
                            step: 1
                        )
                        .frame(width: 180)
                        .accessibilityLabel(Text("Weight", bundle: .strings, comment: "Customize: the figures' weight"))
                        Text(verbatim: "A").font(.system(size: 15, weight: .heavy))
                    }
                    .accessibilityElement(children: .contain)
                } label: {
                    Text("Weight", bundle: .strings, comment: "Customize: the figures' weight")
                }
                Picker(selection: $style.density) {
                    ForEach(CardDensity.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Spacing", bundle: .strings, comment: "Customize: how tightly cards sit")
                }
                .pickerStyle(.segmented)
                Picker(selection: $style.figureSize) {
                    ForEach(FigureSize.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Figure size", bundle: .strings, comment: "Customize: how big figures and chart labels are")
                }
                .pickerStyle(.segmented)
                .help(Text(
                    "Larger makes every figure and chart label bigger, for reading Mactivity from across the desk.",
                    bundle: .strings
                ))
            }
            if !style.isDefault {
                Section {
                    Button(String(localized: "Back to the Defaults", bundle: .strings, comment: "Customize: undoes every choice")) {
                        style.reset()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .animation(Tokens.Motion.figure, value: style.isDefault)
    }
}

/// A setting's name over its choices, side by side.
private struct ChoiceRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(title)
            HStack(spacing: Tokens.Spacing.xs) {
                content
            }
        }
    }
}

/// One choice: a sample on a tile, its name under it, a ring when chosen.
private struct ChoiceButton<Sample: View>: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder let sample: Sample

    var body: some View {
        Button(action: action) {
            VStack(spacing: Tokens.Spacing.xxs) {
                sample
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Tokens.Surfaces.inset, in: .rect(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 2)
                    }
                Text(title)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A figure in a typeface, as a headline would show it. Letters as well as digits: "42%" looked
/// the same in all four.
private struct FigureSample: View {
    let typeface: FigureTypeface
    let weight: Font.Weight

    var body: some View {
        Text(verbatim: "26.8 GB")
            .font(.system(size: 17, weight: weight, design: typeface.design))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
