import SwiftUI

/// Popup window showing all system tray applications.
struct SystemTrayPopup: View {
    @ObservedObject var viewModel: SystemTrayViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "menubar.rectangle")
                    .foregroundColor(.white)
                Text("システムトレイ")
                    .foregroundColor(.white)
                    .font(.headline)
            }
            
            if viewModel.trayItems.isEmpty {
                Text("表示中のアプリケーションはありません")
                    .foregroundColor(.white.opacity(0.6))
                    .font(.subheadline)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.trayItems) { item in
                            Button(action: {
                                viewModel.openApp(item)
                            }) {
                                HStack(spacing: 12) {
                                    Image(nsImage: item.icon)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 24, height: 24)
                                    
                                    Text(item.name)
                                        .foregroundColor(.white)
                                        .font(.subheadline)
                                    
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
        }
        .padding(25)
        .background(Color.black)
        .frame(width: 300, maxHeight: 400)
    }
}

struct SystemTrayPopup_Previews: PreviewProvider {
    static var previews: some View {
        SystemTrayPopup(viewModel: SystemTrayViewModel())
            .previewLayout(.sizeThatFits)
    }
}
