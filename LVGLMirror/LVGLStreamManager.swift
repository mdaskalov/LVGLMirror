//
//  LVGLStreamManager.swift
//  LVGLMirror
//
//  Created by Milko Daskalov on 01.01.26.
//

import SwiftUI
import Combine

enum LVGLStreamState {
    case idle
    case configure
    case streaming
    case error(String)
}

class LVGLStreamManager: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var displayImage: NSImage?
    @Published var streamState: LVGLStreamState = .idle

    private var responseBuffer = Data()
    private var streamingTask: URLSessionDataTask?
    private var backingStore: NSBitmapImageRep?

    private let processingQueue = DispatchQueue(label: "lvgl.process", qos: .userInitiated)
    private let dataPrefix = "\r\nevent:lvgl\r\ndata:".data(using: .utf8)!
    private let newlineByte: UInt8 = 10
  
    private func bitmapImageRep(of w: Int?, h: Int?) -> NSBitmapImageRep? {
        guard let w, let h,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: w,
                  pixelsHigh: h,
                  bitsPerSample: 8,
                  samplesPerPixel: 3,
                  hasAlpha: false,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: w * 3,
                  bitsPerPixel: 24
              ) else { return nil }

        print("created bitmap: \(w)x\(h) (RGB888)")
        
        if let data = rep.bitmapData {
            memset(data, 0, w * h * 3)
        }
        
        return rep
    }
    
    private func parseLVGLPage(from html: String) {
        let pattern = #"<canvas id="canvas" width="(\d+)" height="(\d+)""#
        
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return }
        
        guard let wRange = Range(match.range(at: 1), in: html), let hRange = Range(match.range(at: 2), in: html) else { return }
            
        backingStore = bitmapImageRep(of: Int(html[wRange]), h: Int(html[hRange]))
        
        print("backingStore: \(String(describing: backingStore))")
    }
    
    func fetchSize(from url: URL) {
        URLSession.shared.dataTask(with: url.appending(path: "/lvgl")) { data,_, _ in
            if let data {
                let html = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    self.parseLVGLPage(from: html)
                }
            }
        }.resume()
    }

    func startStreaming(from url: URL) {
        streamingTask?.cancel()
        fetchSize(from: url);
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0          // important for long-lived streams
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url.appending(path: "/lvgl_feed"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        streamingTask = session.dataTask(with: request)
        streamingTask?.resume()
    }

    func stopStreaming() {
        streamingTask?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        processingQueue.async { [weak self] in
            self?.ingestAndProcess(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError?, error.code == NSURLErrorCancelled {
            print("Cancelled")
        } else if let error {
            print("Failed: \(error.localizedDescription)")
        } else {
            print("Stream completed")
        }
    }
    
    private func ingestAndProcess(_ data: Data) {
        responseBuffer.append(data)
         while let prefixRange = responseBuffer.range(of: dataPrefix) {
            let searchStart = prefixRange.upperBound
            guard let endOfLineRange = responseBuffer.range(of: Data([newlineByte]), in: searchStart..<responseBuffer.count) else {
                return // No newLine found skip processing
            }
            let jsonPayload = responseBuffer.subdata(in: searchStart..<endOfLineRange.lowerBound)
            responseBuffer.removeSubrange(0..<endOfLineRange.upperBound)
            if let backingStore, let updatedImage = LVGLProcessor.process(jsonPayload: jsonPayload, backingStore: backingStore) {
                DispatchQueue.main.async {
                    self.displayImage = updatedImage
                }
            }
        }
    }
    
}
