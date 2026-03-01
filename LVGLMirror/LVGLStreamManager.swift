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
    private var updateBuffer = Data()

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
    
    func parseHeader() -> CGRect? {
        let magic = readBuffer.prefix(2).withUnsafeBytes { $0.load(as: UInt16.self) }
        guard magic == LVGLStreamManager.magicValue else {
            print("invalid magic: \(String(format: "0x%04X", magic))")
            return nil
        }
        let x = Int(readBuffer.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self) })
        let y = Int(readBuffer.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) })
        let w = Int(readBuffer.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self) })
        let h = Int(readBuffer.subdata(in: 8..<10).withUnsafeBytes { $0.load(as: UInt16.self) })
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func decompress() -> Int? {
        let expectedPixels = updateBuffer.count / 2
        var pixelsWritten = 0
        let result = readBuffer.withUnsafeBytes { ptr -> Int? in
            guard let base = ptr.bindMemory(to: UInt16.self).baseAddress else { return nil }
            let available = readBuffer.count / 2
            var i = 0

            return updateBuffer.withUnsafeMutableBytes { bufPtr -> Int? in
                guard let bufBase = bufPtr.bindMemory(to: UInt16.self).baseAddress else { return nil }

                while pixelsWritten < expectedPixels {
                    guard i < available else { return nil }
                    let header = base[i]; i += 1

                    if header & 0x8000 != 0 {
                        // repeated block
                        let count = Int(header & 0x7FFF) + 2
                        guard i < available else { return nil }
                        let value = base[i]; i += 1
                        guard pixelsWritten + count <= expectedPixels else { return nil }
                        for _ in 0..<count {
                            bufBase[pixelsWritten] = value
                            pixelsWritten += 1
                        }
                    } else {
                        // raw block
                        let count = Int(header) + 1
                        guard i + count <= available else { return nil }
                        guard pixelsWritten + count <= expectedPixels else { return nil }
                        for j in 0..<count {
                            bufBase[pixelsWritten] = base[i + j]
                            pixelsWritten += 1
                        }
                        i += count
                    }
                }
                return i * 2
            }
        }

        guard let bytesConsumed = result else { return nil }

        let ratio = 1 / Double(bytesConsumed) * Double(pixelsWritten * 2)
        print("Compression ratio: \(String(format: "%.2f", ratio))")

        return bytesConsumed
    }
    
    private func process() {
        if let region = updateRegion {
            updateBuffer.withUnsafeBytes { dataPtr in
                guard let baseAddress = dataPtr.baseAddress else { return }
                var src = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: baseAddress),
                    height: vImagePixelCount(region.height),
                    width: vImagePixelCount(region.width),
                    rowBytes: Int(region.width) * 2
                )
                pixelBuffer?.withUnsafeRegionOfInterest(region) { roiBuffer in
                    roiBuffer.withUnsafeVImageBuffer { dst in
                        var mutableDst = dst
                        vImageConvert_RGB565toRGB888(&src, &mutableDst, vImage_Flags(kvImageNoFlags))
                    }
                }
            }
        }
    }
        
    func startStreaming(from url: URL) {
        streamingTask?.cancel()
        readBuffer.removeAll()
        updateRegion = nil
        updateBuffer.removeAll()
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
        readBuffer.append(data)
        guard case .streaming = streamState else { return }
        if updateRegion != nil {
            if let bytesConsumed = decompress() {
                self.process()
                updateRegion = nil
                readBuffer.removeSubrange(0..<bytesConsumed)
                DispatchQueue.main.async {
                    self.cgImage = self.pixelBuffer?.makeCGImage(cgImageFormat: self.format)
                }
            }
        } else if readBuffer.count >= LVGLStreamManager.headerBytes {
            guard let region = parseHeader() else { streamState = .error("Out of sync"); return }
            updateRegion = region
            updateBuffer = Data(count: Int(region.width * region.height) * 2)
            readBuffer.removeSubrange(0..<LVGLStreamManager.headerBytes)
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

