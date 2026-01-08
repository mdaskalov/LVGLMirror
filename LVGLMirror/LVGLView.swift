//
//  ContentView.swift
//  LVGLMirror
//
//  Created by Milko Daskalov on 01.01.26.
//

import SwiftUI

struct LVGLView: View {
    @StateObject var streamManager = LVGLStreamManager()
    @State var baseURL: String = "http://core2:8881"
    
    var body: some View {
        ZStack {
            // 1. Background layer
            Color.black
                .ignoresSafeArea()
            
            VStack {
                if let img = streamManager.displayImage {
                    Image(nsImage: img)
                        .interpolation(.none) // Keep pixels sharp
                        .resizable()
                        .aspectRatio(contentMode: .fit) // Maintains the 1:1 ratio
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Waiting for stream...")
                        .foregroundColor(.gray)
                        .padding(.top)
                }
//                HStack {
//                    TextField("Base URL", text: $baseURL)
//                        .textFieldStyle(RoundedBorderTextFieldStyle())
//                        .padding()
//                    Button("Start", role: .none) {
//                        if let url = URL(string: baseURL) {
//                            print("started")
//                            streamManager.startStreaming(from: url)
//                        }
//                    }
//                    .buttonStyle(.borderedProminent)
//                    Button("Stop", role: .destructive) {
//                        streamManager.stopStreaming()
//                        
//                    }
//                    .buttonStyle(.bordered)
//                }
            }
        }
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            if let url = URL(string: baseURL) {
                print("started")
                streamManager.startStreaming(from: url)
            }
        }
    }
}

#Preview {
    LVGLView()
}
