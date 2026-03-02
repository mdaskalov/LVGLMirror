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
    
    private var readOffset = 0
    private var writeOffset = 0

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
        return readBuffer.withUnsafeBytes { rawPtr -> Bool in
            let ptr = rawPtr.bindMemory(to: UInt16.self)
            let magic = ptr[0]
            guard magic == LVGLStreamManager.magicValue else {
                print("Out of sync. Got: \(String(format: "0x%04X", magic))")
                return false
            }
            let x = Int(ptr[1])
            let y = Int(ptr[2])
            let w = Int(ptr[3])
            let h = Int(ptr[4])
            updateRegion = CGRect(x: x, y: y, width: w, height: h)
            expectedPixels = w * h
            readOffset = 0
            writeOffset = 0
            updateVImageBuffer.width = vImagePixelCount(w)
            updateVImageBuffer.height = vImagePixelCount(h)
            updateVImageBuffer.rowBytes = w * MemoryLayout<UInt16>.size
            readBuffer.removeFirst(LVGLStreamManager.headerBytes)
            return true
        }
    }

    private func decompress() -> Bool {
        return readBuffer.withUnsafeBytes { readRawPtr -> Bool in
            let readBuf = readRawPtr.bindMemory(to: UInt16.self)
            let available = readBuf.count
            return updateBufferData.withUnsafeMutableBufferPointer { writeBuf -> Bool in
                while writeOffset < expectedPixels && readOffset < available {
                    guard let src = readBuf.baseAddress?.advanced(by: readOffset), let dst = writeBuf.baseAddress?.advanced(by: writeOffset) else { return false }
                    let header = src[0]
                    let isRun = (header & 0x8000) != 0
                    let count = isRun ? Int(header & 0x7FFF) + 2 : Int(header) + 1
                    if isRun {
                        guard readOffset + 1 < available else { break }
                        guard writeOffset + count <= expectedPixels else { return false }
                        dst.initialize(repeating: src[1], count: count)
                        readOffset += 2
                    } else { // Literal mode
                        guard readOffset + 1 + count <= available else { break }
                        guard writeOffset + count <= expectedPixels else { return false }
                        dst.update(from: src.advanced(by: 1), count: count)
                        readOffset += 1 + count
                    }
                    writeOffset += count
                }
                return true
            }
        }
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
                pixelBuffer = vImage.PixelBuffer<vImage.Interleaved8x3>(width: w, height: h)
                pixelBuffer?.withUnsafeVImageBuffer { buf in
                    guard let dataPtr = buf.data else { return }
                    _ = memset(dataPtr, 0, buf.rowBytes * h)
                }
                updateBufferData = ContiguousArray<UInt16>(repeating: 0, count: w * h)
                cgImage = nil
                streamState = .streaming
            }
        }
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Only append and process if we are currently healthy
        guard case .streaming = streamState else { return }
        readBuffer.append(data)
        
        if let region = updateRegion {
            if !decompress() {
                streamState = .error("Decompression failed.")
            } else if writeOffset >= expectedPixels {
                updateBufferData.withUnsafeMutableBufferPointer { arrayPtr in
                    updateVImageBuffer.data = UnsafeMutableRawPointer(arrayPtr.baseAddress!)
                    pixelBuffer?.withUnsafeRegionOfInterest(region) { roiBuffer in
                        roiBuffer.withUnsafeVImageBuffer { dst in
                            var mutableDst = dst
                            vImageConvert_RGB565toRGB888(&updateVImageBuffer, &mutableDst, vImage_Flags(kvImageNoFlags))
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.cgImage = self.pixelBuffer?.makeCGImage(cgImageFormat: self.format)
                }
                readBuffer.removeFirst(readOffset * 2)
                updateRegion = nil // wait for next header
            }
        } else if readBuffer.count >= LVGLStreamManager.headerBytes && !parseHeader() {
            streamState = .error("Out of sync.")
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
