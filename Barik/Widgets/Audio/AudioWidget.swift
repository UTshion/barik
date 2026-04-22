import SwiftUI

/// Widget for controlling audio input/output devices and volume.
struct AudioWidget: View {
    @StateObject private var viewModel = AudioViewModel()
    @State private var rect: CGRect = .zero

    var body: some View {
        HStack(spacing: 8) {
            // Output volume icon
            Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 15))
                .foregroundColor(.foregroundOutside)
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { rect = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, newValue in
                        rect = newValue
                    }
            }
        )
        .contentShape(Rectangle())
        .font(.system(size: 15))
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.001))
        .onTapGesture {
            MenuBarPopup.show(rect: rect, id: "audio") { AudioPopup(viewModel: viewModel) }
        }
    }
}

struct AudioWidget_Previews: PreviewProvider {
    static var previews: some View {
        AudioWidget()
            .frame(width: 200, height: 100)
            .background(Color.black)
    }
}
