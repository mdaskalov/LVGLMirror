//
//  ContentView.swift
//  LVGLMirror
//
//  Created by Milko Daskalov on 01.01.26.
//

import SwiftUI

struct LVGLView: View {
    @StateObject var streamManager = LVGLStreamManager()
    @State var baseURL: String = "http://office-th:8881"
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            VStack {
                Group {
                    switch streamManager.streamState {
                    case .idle:
                        Spacer()
                    case .started, .configured:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    case .streaming:
                        if let img = streamManager.displayImage {
                            Image(nsImage: img)
                                .interpolation(.none) // Keep pixels sharp
                                .resizable()
                                .aspectRatio(contentMode: .fit) // Maintains the 1:1 ratio
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .error(let message):
                        Text("Error: \(message)")
                            .font(.title)
                            .foregroundColor(.red)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    TextField("Base URL", text: $baseURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button(action: {
                        if streamManager.isStreaming {
                            streamManager.stopStreaming()
                        } else if let url = URL(string: baseURL) {
                            streamManager.startStreaming(from: url)
                        }
                    }) {
                        // Dynamically change the icon based on state
                        Image(systemName: streamManager.isStreaming ? "stop.fill" : "play.fill")
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
        .edgesIgnoringSafeArea(.all)
//        .onAppear {
//            if let url = URL(string: baseURL) {
//                print("started")
//                streamManager.startStreaming(from: url)
//            }
//        }
    }
}

#Preview {
    LVGLView()
}
