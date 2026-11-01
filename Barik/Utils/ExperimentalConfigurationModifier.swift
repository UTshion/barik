import SwiftUI

extension EnvironmentValues {
    /// Height available to widget backgrounds (e.g. the spaces pills) on the
    /// display the bar is rendered on. Set per display by `MenuBarView`.
    @Entry var barikWidgetHeight: CGFloat = Constants.widgetContentHeight
}

private struct ExperimentalConfigurationModifier: ViewModifier {
    @ObservedObject var configManager = ConfigManager.shared
    @Environment(\.barikWidgetHeight) private var widgetHeight
    var foregroundHeight: CGFloat { configManager.config.experimental.foreground.resolveHeight() }

    let horizontalPadding: CGFloat
    let cornerRadius: CGFloat
    
    func body(content: Content) -> some View {
        Group {
            if !configManager.config.experimental.foreground.widgetsBackground.displayed {
                content
            } else {
                content
                    .frame(height: foregroundHeight < 45 ? widgetHeight : 38)
                    .padding(.horizontal, foregroundHeight < 45 && horizontalPadding != 15 ? 0 :
                                foregroundHeight < 30 ? 0 : horizontalPadding
                    )
                    .background(configManager.config.experimental.foreground.widgetsBackground.blur)
                    .cornerRadius(foregroundHeight < 30 ? 0 : cornerRadius)
                    .overlay(
                        foregroundHeight < 30 ? nil :
                            Capsule().stroke(Color.noActive, lineWidth: 1)
                    )
            }
        }.scaleEffect(foregroundHeight < 25 ? 0.9 : 1, anchor: .leading)
    }
}

extension View {
    /// Makes the whole frame of this view clickable inside Barik's bar.
    ///
    /// The window server lets clicks fall through fully transparent pixels of
    /// the bar panel to the system menu bar below, so a widget's gaps (between
    /// glyphs, icons, …) need a nearly invisible fill to stay hittable. The
    /// alpha must survive 8-bit quantization (1/255 ≈ 0.004), hence 0.01.
    func barikHitArea() -> some View {
        self
            .contentShape(Rectangle())
            .background(Color.black.opacity(0.01))
    }

    func experimentalConfiguration(
        horizontalPadding: CGFloat = 15,
        cornerRadius: CGFloat
    ) -> some View {
        self.modifier(ExperimentalConfigurationModifier(
            horizontalPadding: horizontalPadding,
            cornerRadius: cornerRadius
        ))
    }
}
