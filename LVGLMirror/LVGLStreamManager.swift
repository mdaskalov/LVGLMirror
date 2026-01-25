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

struct LVGLPacketHeader {
    static let size: Int = 14 // 4(LVGL) + 2(len) + 2(x) + 2(y) + 2(w) + 2(h)
    static let magicValue: UInt32 = 0x4C56474C // LVGL
    static let magicData: Data = {
        var magic = magicValue
        return withUnsafeBytes(of: &magic) { Data($0) }
    }()
    
    let region: CGRect
    let dataRange: Range<Data.Index>

    init?(data: Data) {
        guard data.count >= LVGLPacketHeader.size else { return nil }
        let magic = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        guard magic == LVGLPacketHeader.magicValue else {
            print("invalid magic: \(String(format: "0x%08X", magic))")
            return nil
        }
        let x = Int(data.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) })
        let y = Int(data.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self) })
        let w = Int(data.subdata(in: 8..<10).withUnsafeBytes { $0.load(as: UInt16.self) })
        let h = Int(data.subdata(in: 10..<12).withUnsafeBytes { $0.load(as: UInt16.self) })
        let len = w * h * 2
        self.region = CGRect(x: x, y: y, width: w, height: h)
        self.dataRange = 0..<Int(len) + LVGLPacketHeader.size
    }
}

class LVGLStreamManager: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var streamState: LVGLStreamState = .idle
    @Published var cgImage: CGImage?
    
    var aspectRatio: CGFloat = 1.0
    
    var streaming: Bool {
        if case .streaming = streamState { return true }
        return false
    }
    
    private var streamBuffer = Data()
    private var streamingTask: URLSessionDataTask?
    
    private var pixelBuffer: vImage.PixelBuffer<vImage.Interleaved8x3>?
    private var format: vImage_CGImageFormat = {
        vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            colorSpace: Unmanaged.passUnretained(CGColorSpaceCreateDeviceRGB()),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
    }()
    
    private func process(region: CGRect, data: Data) {
        data.withUnsafeBytes { dataPtr in
            guard let baseAddress = dataPtr.baseAddress else { return }
            var src = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: baseAddress),
                height: vImagePixelCount(region.height),
                width: vImagePixelCount(region.width),
                rowBytes: Int(region.width) * 2 // RGB565 is 2 bytes per pixel
            )
            pixelBuffer?.withUnsafeRegionOfInterest(region) { roiBuffer in
                roiBuffer.withUnsafeVImageBuffer { dst in
                    var mutableDst = dst
                    vImageConvert_RGB565toRGB888(&src, &mutableDst, vImage_Flags(kvImageNoFlags))
                }
            }
            // Push to main thread only for the final assignment
            self.cgImage = pixelBuffer?.makeCGImage(cgImageFormat: format)
        }
    }
        
    func startStreaming(from url: URL) {
        streamingTask?.cancel()
        streamBuffer.removeAll()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        streamingTask = session.dataTask(with: url)
        streamState = .started
        streamingTask?.resume()
    }

    func stopStreaming() {
        streamingTask?.cancel()
    }
       
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        streamState = .error("Invalid response")
        if let response = response as? HTTPURLResponse, let screenSize = response.value(forHTTPHeaderField: "Screen-Size") {
            let parts = screenSize.split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                aspectRatio = CGFloat(w) / CGFloat(h)
                print("Screen size: \(w)x\(h) aspectRatio: \(aspectRatio)")
                pixelBuffer = vImage.PixelBuffer<vImage.Interleaved8x3>(width: w, height: h)
                pixelBuffer?.withUnsafeVImageBuffer { buf in
                    _ = memset(buf.data, 0, buf.rowBytes * h)
                }
                cgImage = nil
                streamState = .streaming
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        streamBuffer.append(data)
        guard case .streaming = streamState else { return }
        
        while streamBuffer.count >= LVGLPacketHeader.size {
            let packetHeader = LVGLPacketHeader(data: streamBuffer)
            if let header = packetHeader, streamBuffer.count >= header.dataRange.upperBound {
                let payloadRange = LVGLPacketHeader.size..<header.dataRange.upperBound
                let pixelData = streamBuffer.subdata(in: payloadRange)
                streamBuffer.removeSubrange(header.dataRange)
                DispatchQueue.main.async {
                    self.process(region: header.region, data: pixelData)
                }
            } else if packetHeader == nil {
                if let nextMagicRange = streamBuffer.range(of: LVGLPacketHeader.magicData) {
                    print("Out of sync: discarding \(nextMagicRange.lowerBound) bytes.")
                    streamBuffer.removeSubrange(0..<nextMagicRange.lowerBound)
                    continue // try parsing at the new start position
                } else {
                    let bytesToKeep = min(streamBuffer.count, 3) // keep the last 3 bytes, in case "LVGL" was split across packets
                    print("Out of sync: dropping \(streamBuffer.count - bytesToKeep) bytes.")
                    streamBuffer.removeSubrange(0..<(streamBuffer.count - bytesToKeep))
                    break
                }
            } else {
                break
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let err = error as NSError? {
            streamState = err.code == NSURLErrorCancelled ? .idle : .error(err.localizedDescription)
        }
        else {
            if case .streaming = streamState {
                streamState = .idle
            }
            streamingTask?.cancel()
        }
    }
    
}

