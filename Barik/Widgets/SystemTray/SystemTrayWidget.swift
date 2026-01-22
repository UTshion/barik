import SwiftUI

/// Widget for displaying system tray (menu bar) applications.
struct SystemTrayWidget: View {
    @StateObject private var viewModel = SystemTrayViewModel()
    @State private var rect: CGRect = .zero
    
    var body: some View {
        if !viewModel.trayItems.isEmpty {
            HStack(spacing: 6) {
                ForEach(viewModel.trayItems.prefix(10)) { item in
                    Button(action: {
                        viewModel.openApp(item)
                    }) {
                        Image(nsImage: item.icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(item.name)
                }
                
                if viewModel.trayItems.count > 10 {
                    Button(action: {
                        MenuBarPopup.show(rect: rect, id: "systemtray") {
                            SystemTrayPopup(viewModel: viewModel)
                        }
                    }) {
                        Text("+\(viewModel.trayItems.count - 10)")
                            .font(.system(size: 10))
                            .foregroundColor(.foregroundOutside)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
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
            .experimentalConfiguration(cornerRadius: 15)
            .frame(maxHeight: .infinity)
            .background(.black.opacity(0.001))
            .onTapGesture {
                MenuBarPopup.show(rect: rect, id: "systemtray") {
                    SystemTrayPopup(viewModel: viewModel)
                }
            }
        }
    }
}

struct SystemTrayWidget_Previews: PreviewProvider {
    static var previews: some View {
        SystemTrayWidget()
            .frame(width: 200, height: 100)
            .background(Color.black)
    }
}
