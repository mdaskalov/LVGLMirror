//
//  LVGLStreamManager.swift
//  LVGLMirror
//
//  Created by Milko Daskalov on 01.01.26.
//

import SwiftUI
import Combine
import Accelerate

enum LVGLStreamState: Equatable {
    case idle
    case started
    case streaming
    case error(String)
}

class LVGLStreamManager: NSObject, ObservableObject, URLSessionDataDelegate {
    static let magicValue: UInt16 = 0x564C // LV
    static let headerBytes: Int = 10 // 2(LV) + 2(x) + 2(y) + 2(w) + 2(h)

    @Published var streamState: LVGLStreamState = .idle
    @Published var cgImage: CGImage?
    
    var aspectRatio: CGFloat = 1.0
    
    var streaming: Bool { switch streamState {
        case .started, .streaming: true
        default : false
        }
    }
    
    private var streamingTask: URLSessionDataTask?
    private var readBuffer = Data()
    
    private var updateRegion: CGRect?
    
    private var expectedPixels = 0
    private var decompressedPixels = 0
    private var updateVImageBuffer = vImage_Buffer()
    private var updateBufferData: ContiguousArray<UInt16> = []

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
    
    func parseHeader() -> Bool {
        let magic = readBuffer.prefix(2).withUnsafeBytes { $0.load(as: UInt16.self) }
        guard magic == LVGLStreamManager.magicValue else {
            print("invalid magic: \(String(format: "0x%04X", magic))")
            return false
        }
        let x = Int(readBuffer.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self) })
        let y = Int(readBuffer.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) })
        let w = Int(readBuffer.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self) })
        let h = Int(readBuffer.subdata(in: 8..<10).withUnsafeBytes { $0.load(as: UInt16.self) })
        updateRegion = CGRect(x: x, y: y, width: w, height: h)
        expectedPixels = w * h
        decompressedPixels = 0
        updateVImageBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: updateBufferData.withUnsafeBufferPointer { $0.baseAddress }),
            height: vImagePixelCount(h),
            width: vImagePixelCount(w),
            rowBytes: w * MemoryLayout<UInt16>.size
        )
        return true
    }

    private func decompress() -> Int? {
        guard !updateBufferData.isEmpty else { return nil }
        
        decompressedPixels = 0
        
        let result = readBuffer.withUnsafeBytes { readBufPtr -> Int? in
            guard let readBuf = readBufPtr.bindMemory(to: UInt16.self).baseAddress else { return nil }
            let available = readBuffer.count / 2
            var i = 0

            return updateBufferData.withUnsafeMutableBufferPointer { updateBuf -> Int? in
                while decompressedPixels < expectedPixels {
                    guard i < available else { return nil }
                    let header = readBuf[i]; i += 1

                    if header & 0x8000 != 0 {
                        let count = Int(header & 0x7FFF) + 2
                        guard i < available else { return nil }
                        let value = readBuf[i]; i += 1
                        guard decompressedPixels + count <= expectedPixels else { return nil }
                        let destPtr = updateBuf.baseAddress!.advanced(by: decompressedPixels)
                        destPtr.initialize(repeating: value, count: count)
                        decompressedPixels += count
                    } else {
                        let count = Int(header) + 1
                        guard i + count <= available else { return nil }
                        guard decompressedPixels + count <= expectedPixels else { return nil }
                        for j in 0..<count {
                            updateBuf[decompressedPixels] = readBuf[i + j]
                            decompressedPixels += 1
                        }
                        i += count
                    }
                }
                return i * 2
            }
        }

        guard let bytesConsumed = result else { return nil }
        print("Compression ratio: \(String(format: "%.2f", Double(decompressedPixels * 2) / Double(bytesConsumed)))")
        return bytesConsumed
    }
    
    func startStreaming(from url: URL) {
        streamingTask?.cancel()
        readBuffer.removeAll()
        updateRegion = nil
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
       
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
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
                updateBufferData = ContiguousArray<UInt16>(repeating: 0, count: w * h)
                cgImage = nil
                streamState = .streaming
            }
        }
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        readBuffer.append(data)
        guard case .streaming = streamState else { return }
        if let region = updateRegion {
            if let bytesConsumed = decompress() {
                if decompressedPixels >= expectedPixels {
                    updateRegion = nil
                    pixelBuffer?.withUnsafeRegionOfInterest(region) { roiBuffer in
                        roiBuffer.withUnsafeVImageBuffer { dst in
                            var mutableDst = dst
                            vImageConvert_RGB565toRGB888(&updateVImageBuffer, &mutableDst, vImage_Flags(kvImageNoFlags))
                        }
                    }
                    DispatchQueue.main.async {
                        self.cgImage = self.pixelBuffer?.makeCGImage(cgImageFormat: self.format)
                    }
                }
                readBuffer.removeSubrange(0..<bytesConsumed)
            }
        } else if readBuffer.count >= LVGLStreamManager.headerBytes {
            guard parseHeader() else { streamState = .error("Out of sync"); return }
            readBuffer.removeSubrange(0..<LVGLStreamManager.headerBytes)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let err = error as NSError? {
            streamState = err.code == NSURLErrorCancelled ? .idle : .error(err.localizedDescription)
        }
        else {
            if case .streaming = streamState { streamState = .idle }
            streamingTask?.cancel()
        }
    }
}
