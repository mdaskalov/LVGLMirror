//
//  ContentView.swift
//  LVGLMirror
//
//  Created by Milko Daskalov on 01.01.26.
//

import SwiftUI

@Observable
class TouchThrottle {
    private var timer: Timer?
    private var pendingX: Int = 0
    private var pendingY: Int = 0
    
    var onSend: ((Int, Int, Int) -> Void)?
    
    func touchChanged(x: Int, y: Int) {
        pendingX = x
        pendingY = y
        
        guard timer == nil else { return }
        
        onSend?(x, y, 1)
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onSend?(self.pendingX, self.pendingY, 1)
        }
    }
    
    func touchEnded(x: Int, y: Int) {
        timer?.invalidate()
        timer = nil
        onSend?(x, y, 0)
    }
}

struct LVGLView: View {
    @StateObject var streamManager = LVGLStreamManager()
    @State var host: String = "office-th"
    
    private var touchTimer: Timer?
    private var pendingTouchX: Int = 0
    private var pendingTouchY: Int = 0
    private var pendingTouches: Int = 0
    
    func normalizedTouch(at p: CGPoint, in s: CGSize, on i: CGImage) -> (Int, Int) {
        (
            Int(p.x * CGFloat(i.width) / s.width),
            Int(p.y * CGFloat(i.height) / s.height)
        )
    }
    
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
                Button(action: { streaming ? streamManager.stopStreaming() : streamManager.startStreaming(from: host) }) {
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
