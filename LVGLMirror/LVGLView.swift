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
                    Canvas(opaque: true) { context, size in
                        if let cgImage = streamManager.cgImage {
                            let image = Image(decorative: cgImage, scale: 1.0)
                                .interpolation(.none)
                            context.draw(image, in: CGRect(origin: .zero, size: size))
                        }
                    }
                    .aspectRatio(streamManager.aspectRatio, contentMode: .fit)
                case .error(let message):
                    Text("Error: \(message)")
                        .font(.headline)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                TextField("Host", text: $host)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button(action: {
                    if streamManager.streaming {
                        streamManager.stopStreaming()
                    } else if let url = URL(string: "http://\(host):8881") {
                        streamManager.startStreaming(from: url)
                    }
                }) {
                    // Dynamically change the icon based on state
                    Image(systemName: streamManager.streaming ? "stop.fill" : "play.fill")
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
