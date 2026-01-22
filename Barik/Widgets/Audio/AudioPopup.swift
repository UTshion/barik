import SwiftUI

/// Popup window for audio control with volume adjustment and device selection.
struct AudioPopup: View {
    @ObservedObject var viewModel: AudioViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Output Section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.white)
                    Text("出力")
                        .foregroundColor(.white)
                        .font(.headline)
                }
                
                // Volume Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("音量")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.subheadline)
                        Spacer()
                        Text("\(Int(viewModel.outputVolume * 100))%")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.subheadline)
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            viewModel.toggleMute()
                        }) {
                            Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        Slider(value: Binding(
                            get: { viewModel.outputVolume },
                            set: { newValue in
                                viewModel.setOutputVolume(newValue)
                                if viewModel.isMuted && newValue > 0 {
                                    viewModel.isMuted = false
                                }
                            }
                        ), in: 0...1)
                        .accentColor(.white)
                    }
                }
                
                // Output Device Selection
                if !viewModel.outputDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("出力デバイス")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.subheadline)
                        
                        ForEach(viewModel.outputDevices) { device in
                            Button(action: {
                                viewModel.selectOutputDevice(device)
                            }) {
                                HStack {
                                    Circle()
                                        .fill(viewModel.selectedOutputDevice?.id == device.id ? Color.white : Color.white.opacity(0.3))
                                        .frame(width: 8, height: 8)
                                    Text(device.name)
                                        .foregroundColor(.white)
                                        .font(.subheadline)
                                    Spacer()
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // Input Section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "mic.fill")
                        .foregroundColor(.white)
                    Text("入力")
                        .foregroundColor(.white)
                        .font(.headline)
                }
                
                // Input Volume Slider
                if !viewModel.inputDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("入力音量")
                                .foregroundColor(.white.opacity(0.8))
                                .font(.subheadline)
                            Spacer()
                            Text("\(Int(viewModel.inputVolume * 100))%")
                                .foregroundColor(.white.opacity(0.8))
                                .font(.subheadline)
                        }
                        
                        Slider(value: Binding(
                            get: { viewModel.inputVolume },
                            set: { newValue in
                                viewModel.setInputVolume(newValue)
                            }
                        ), in: 0...1)
                        .accentColor(.white)
                    }
                }
                
                // Input Device Selection
                if !viewModel.inputDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("入力デバイス")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.subheadline)
                        
                        ForEach(viewModel.inputDevices) { device in
                            Button(action: {
                                viewModel.selectInputDevice(device)
                            }) {
                                HStack {
                                    Circle()
                                        .fill(viewModel.selectedInputDevice?.id == device.id ? Color.white : Color.white.opacity(0.3))
                                        .frame(width: 8, height: 8)
                                    Text(device.name)
                                        .foregroundColor(.white)
                                        .font(.subheadline)
                                    Spacer()
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // System Preferences Button
            Button(action: {
                viewModel.openSystemSoundPreferences()
            }) {
                HStack {
                    Image(systemName: "gear")
                        .foregroundColor(.white)
                    Text("システム環境設定を開く")
                        .foregroundColor(.white)
                        .font(.subheadline)
                    Spacer()
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(25)
        .background(Color.black)
    }
}

struct AudioPopup_Previews: PreviewProvider {
    static var previews: some View {
        AudioPopup(viewModel: AudioViewModel())
            .previewLayout(.sizeThatFits)
    }
}
