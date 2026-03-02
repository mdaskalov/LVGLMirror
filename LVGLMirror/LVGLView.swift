//
//  ContentView.swift
//  LVGLMirror
//
//  Created by Milko Daskalov on 01.01.26.
//

import SwiftUI

struct LVGLView: View {
    @StateObject var streamManager = LVGLStreamManager()
    @State var host: String = "office-th"
    
    var body: some View {
        VStack {
            Group {
                switch streamManager.streamState {
                case .idle:
                    Color.clear
                case .started:
                    ProgressView()
                case .streaming:
                    if let cgImage = streamManager.cgImage {
                        Image(decorative: cgImage, scale: 1.0)
                            .resizable()
                            .aspectRatio(CGFloat(cgImage.width / cgImage.height), contentMode: .fit)
                    } else {
                        Color.clear
                    }
                case .error(let message):
                    Text("Error: \(message)")
                        .font(.headline)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                let streaming = switch streamManager.streamState {
                case .started, .streaming: true
                default: false
                }
                TextField("Host", text: $host)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button(action: {
                    if streaming {
                        streamManager.stopStreaming()
                    } else if let url = URL(string: "http://\(host):8881") {
                        streamManager.startStreaming(from: url)
                    }
                }) {
                    Image(systemName: streaming ? "stop.fill" : "play.fill")
                        .font(.title2)
                        .fontWeight(.bold)
                }
                .buttonBorderShape(.circle)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
            }
            .padding()
        }
    }
}

#Preview {
    LVGLView()
}
