//
//  LVGLStreamManager.swift
//  LVGLMirror
//
//  Created by Milko Daskalov on 01.01.26.
//

import SwiftUI
import Combine
import Accelerate

enum LVGLStreamState {
    case idle
    case started
    case configured
    case streaming
    case error(String)
}

class LVGLStreamManager: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var streamState: LVGLStreamState = .idle
    @Published var displayImage: NSImage?

    private var pageBuffer = Data()
    private var streamBuffer = Data()
    private var streamingTask: URLSessionDataTask?
    private var backingStore: NSBitmapImageRep?

    private let processingQueue = DispatchQueue(label: "lvgl.process", qos: .userInitiated)
    private let dataPrefix = "\r\nevent:lvgl\r\ndata:".data(using: .utf8)!
    private let lvglPagePattern = #"<canvas id="canvas" width="(\d+)" height="(\d+)""#
    private let newlineByte: UInt8 = 10
    
    
    var isStarted: Bool {
        if case .started = streamState { return true }
        return false
    }
    
    var isStreaming: Bool {
        if case .configured = streamState { return true }
        if case .streaming = streamState { return true }
        return false
    }
  
    private func parseLVGLPage(from html: String) {
        guard let regex = try? NSRegularExpression(pattern: lvglPagePattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return }
        guard let wRange = Range(match.range(at: 1), in: html), let hRange = Range(match.range(at: 2), in: html) else { return }
        if let w = Int(html[wRange]), let h = Int(html[hRange]) {
            backingStore = LVGLProcessor.backingStore(of: w, h: h)
        }
    }
    
    func startStreaming(from url: URL) {
        streamingTask?.cancel()
        pageBuffer = Data()
        streamBuffer = Data()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        streamingTask = session.dataTask(with: url.appendingPathComponent("lvgl"))
        streamState = .started
        streamingTask?.resume()
    }

    func stopStreaming() {
        streamingTask?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if isStarted {
            pageBuffer.append(data)
        } else if isStreaming {
            processingQueue.async { [weak self] in
                guard let self = self else { return }
                streamBuffer.append(data)
                while let prefixRange = streamBuffer.range(of: dataPrefix) {
                    let searchStart = prefixRange.upperBound
                    guard let endOfLineRange = streamBuffer.range(of: Data([newlineByte]), in: searchStart..<streamBuffer.count) else {
                        return // No eol found
                    }
                    let jsonPayload = streamBuffer.subdata(in: searchStart..<endOfLineRange.lowerBound)
                    streamBuffer.removeSubrange(0..<endOfLineRange.upperBound)
                    if let backingStore, let displayImage = LVGLProcessor.process(jsonPayload: jsonPayload, backingStore: backingStore) {
                        DispatchQueue.main.async {
                            self.streamState = .streaming
                            self.displayImage = displayImage
                        }
                    }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? {
            streamState = error.code == NSURLErrorCancelled ? .idle : .error(error.localizedDescription)
        } else if isStarted {
            self.parseLVGLPage(from: String(decoding: pageBuffer, as: UTF8.self))
            if let url = streamingTask?.originalRequest?.url?.deletingLastPathComponent().appendingPathComponent("lvgl_feed") {
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 0 // No timeout for stream
                let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
                streamingTask = session.dataTask(with: url)
                streamState = .configured
                streamingTask?.resume()
            } else {
                streamState = .error("Can't retrieve stereaming event URL")
            }
        }
    }
    
}
