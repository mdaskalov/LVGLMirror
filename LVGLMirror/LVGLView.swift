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
                            .aspectRatio(streamManager.aspectRatio, contentMode: .fit)
                            .overlay(
                                GeometryReader { g in
                                    let scaleX = CGFloat(cgImage.width) / g.size.width
                                    let scaleY = CGFloat(cgImage.height) / g.size.height
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .gesture(
                                            DragGesture(minimumDistance: 0)
                                                .onChanged { value in
                                                    let x = Int(value.location.x * scaleX)
                                                    let y = Int(value.location.y * scaleY)
                                                    sendTouchEvent(atX: x, y: y, touches: 1)
                                                }
                                                .onEnded { value in
                                                    let x = Int(value.location.x * scaleX)
                                                    let y = Int(value.location.y * scaleY)
                                                    sendTouchEvent(atX: x, y: y, touches: 0)
                                                }
                                        )
                                }
                            )
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
    
    private func sendTouchEvent(atX x: Int, y: Int, touches: Int) {
        guard let url = URL(string: "http://\(host)/lvgl_touch") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "x=\(x)&y=\(y)&t=\(touches)".data(using: .utf8)
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error = error {
                print("Touch event error: \(error)")
            }
        }.resume()
    }
}

#Preview {
    LVGLView()
}
