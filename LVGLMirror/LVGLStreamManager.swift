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
    case streaming
    case error(String)
}

class LVGLStreamManager: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var streamState: LVGLStreamState = .idle
    @Published var cgImage: CGImage?
    
    var aspectRatio: CGFloat = 1.0

    var started: Bool {
        if case .started = streamState { return true }
        return false
    }
    
    var streaming: Bool {
        if case .streaming = streamState { return true }
        return false
    }
    
    private var pageBuffer = Data()
    private var streamBuffer = Data()
    private var streamingTask: URLSessionDataTask?
    
    private var pixelBuffer: vImage.PixelBuffer<vImage.Interleaved8x3>?
    private lazy var format: vImage_CGImageFormat = {
        vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            colorSpace: Unmanaged.passRetained(CGColorSpaceCreateDeviceRGB()),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
    }()
    
    private let processingQueue = DispatchQueue(label: "lvgl.process", qos: .userInitiated)
    private let dataPrefix = "\r\nevent:lvgl\r\ndata:".data(using: .utf8)!
    private let lvglPagePattern = #"<canvas id="canvas" width="(\d+)" height="(\d+)""#
    private let newlineByte: UInt8 = 10
    
    private struct LVGLUpdate: Codable, Sendable {
        let x1, y1, x2, y2: Int
        let b64: String?
    }
    
    private func parseLVGLPage(from html: String) {
        guard let regex = try? NSRegularExpression(pattern: lvglPagePattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return }
        guard let wRange = Range(match.range(at: 1), in: html), let hRange = Range(match.range(at: 2), in: html) else { return }
        if let w = Int(html[wRange]), let h = Int(html[hRange]) {
            // Allocate back buffer using vImage's alignment-aware allocation
            aspectRatio = CGFloat(w) / CGFloat(h)
            print("screen size: \(w)x\(h) aspectRatio: \(aspectRatio)")
            pixelBuffer = vImage.PixelBuffer<vImage.Interleaved8x3>(width: w, height: h)           
            pixelBuffer?.withUnsafeVImageBuffer { buf in
                _ = memset(buf.data, 0, buf.rowBytes * h)
            }
        }
    }
    
    private func process(jsonPayload: Data) {
        guard let update = try? JSONDecoder().decode(LVGLUpdate.self, from: jsonPayload),
              let b64 = update.b64,
              let pixelBuffer else { return }

        let width  = update.x2 - update.x1 + 1
        let height = update.y2 - update.y1 + 1
        let ROI = CGRect(x: update.x1, y: update.y1, width: width, height: height)
        
        guard width > 0, height > 0 else { return }

        Data(base64Encoded: b64)?.withUnsafeBytes { dataPtr in
            guard let baseAddress = dataPtr.baseAddress else { return }
            var src = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: baseAddress),
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width * 2 // RGB565 is 2 bytes per pixel
            )
            pixelBuffer.withUnsafeRegionOfInterest(ROI) { roiBuffer in
                roiBuffer.withUnsafeVImageBuffer { dst in
                    var mutableDst = dst
                    vImageConvert_RGB565toRGB888(&src, &mutableDst, vImage_Flags(kvImageNoFlags))
                }
            }
            cgImage = pixelBuffer.makeCGImage(cgImageFormat: format)
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
        if started {
            pageBuffer.append(data)
        } else if streaming {
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
                    DispatchQueue.main.async {
                        self.process(jsonPayload: jsonPayload)
                    }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let err = error as NSError? {
            streamState = err.code == NSURLErrorCancelled ? .idle : .error(err.localizedDescription)
        } else if started {
            self.parseLVGLPage(from: String(decoding: pageBuffer, as: UTF8.self))
            if let url = streamingTask?.originalRequest?.url?.deletingLastPathComponent().appendingPathComponent("lvgl_feed") {
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 3600
                config.waitsForConnectivity = true
                let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
                streamingTask = session.dataTask(with: url)
                cgImage = nil
                streamState = .streaming
                streamingTask?.resume()
            } else {
                streamState = .error("Can't retrieve stereaming event URL")
            }
        }
    }
    
}
