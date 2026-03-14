//
//  ContentView.swift
//  LVGLMirror
//
//  Created by Milko Daskalov on 01.01.26.
//

import SwiftUI

struct LVGLView: View {
    @StateObject var streamManager = LVGLStreamManager()
    
    private var touchTimer: Timer?
    private var pendingTouchX: Int = 0
    private var pendingTouchY: Int = 0
    private var pendingTouches: Int = 0
       
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
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .gesture(dragGestureIn(geometry: g))
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
                TextField("Host", text: $streamManager.host)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit(streamManager.startStreaming)
                Button(action: streaming ? streamManager.stopStreaming : streamManager.startStreaming) {
                    Image(systemName: streaming ? "stop.fill" : "play.fill")
                        .imageScale(.large)
                        .frame(width: 20, height: 20)
                }
                .buttonBorderShape(.circle)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding([.leading, .bottom, .trailing])
        }
    }

    func dragGestureIn(geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                streamManager.touchChanged(to: value.location, in: geometry)
            }
            .onEnded { value in
                streamManager.touchEnded(at: value.location, in: geometry)
            }
    }
}

#Preview {
    LVGLView()
}
