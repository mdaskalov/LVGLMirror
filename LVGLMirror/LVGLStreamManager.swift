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
    @Published var streamState: LVGLStreamState = .idle
    @Published var cgImage: CGImage?
    @Published var aspectRatio: CGFloat = 1.0

    private var streamingTask: URLSessionDataTask?
    
    private var readOffset = 0
    private var readBuffer = Data()

    private var updateRegion: CGRect?
    private var expectedPixels = 0
    private var writeOffset = 0
    private var writeBuffer: ContiguousArray<UInt16> = []

    private var imageBuffer: vImage.PixelBuffer<vImage.Interleaved8x3>?

    func parseHeader() -> Bool {
        let magicValue: UInt16 = 0x564C // LV
        let headerBytes: Int = 10 // 2(LV) + 2(x) + 2(y) + 2(w) + 2(h)
        guard readBuffer.count >= headerBytes else { return true }
        return readBuffer.withUnsafeBytes { rawPtr -> Bool in
            let hdr = rawPtr.bindMemory(to: UInt16.self)
            guard hdr[0] == magicValue else { return false }
            let (x, y, w, h) = (Int(hdr[1]), Int(hdr[2]), Int(hdr[3]), Int(hdr[4]))
            updateRegion = CGRect(x: x, y: y, width: w, height: h)
            expectedPixels = w * h
            readOffset = 0
            writeOffset = 0
            readBuffer.removeFirst(headerBytes)
            return true
        }
    }
    
    private func decompress() -> Bool {
        return readBuffer.withUnsafeBytes { readRawPtr -> Bool in
            let readBuf = readRawPtr.assumingMemoryBound(to: UInt16.self)
            return writeBuffer.withUnsafeMutableBufferPointer { writeBuf -> Bool in
                guard let srcBase = readBuf.baseAddress, let dstBase = writeBuf.baseAddress else { return false }
                let available = readBuf.count
                while writeOffset < expectedPixels && readOffset < available {
                    let src = srcBase.advanced(by: readOffset)
                    let header = src[0]
                    let isRun = (header & 0x8000) != 0
                    let count = isRun ? Int(header & 0x7FFF) + 2 : Int(header) + 1
                    guard readOffset + 1 + (isRun ? 1 : count) <= available, writeOffset + count <= expectedPixels else { break }
                    let dst = dstBase.advanced(by: writeOffset)
                    if isRun {
                        dst.initialize(repeating: src[1], count: count)
                        readOffset += 2
                    } else { // isLiteral
                        dst.update(from: src.advanced(by: 1), count: count)
                        readOffset += 1 + count
                    }
                    writeOffset += count
                }
                return true
            }
        }
    }
    
    func processUpdate(region: CGRect) {
        writeBuffer.withUnsafeMutableBufferPointer { arrayPtr in
            imageBuffer?.withUnsafeRegionOfInterest(region) { roiBuffer in
                roiBuffer.withUnsafeVImageBuffer { dst in
                    let w = Int(region.width)
                    let h = Int(region.height)
                    var src = vImage_Buffer(
                        data: UnsafeMutableRawPointer(arrayPtr.baseAddress!),
                        height: vImagePixelCount(h),
                        width: vImagePixelCount(w),
                        rowBytes: w * MemoryLayout<UInt16>.size
                    )
                    var mutableDst = dst
                    vImageConvert_RGB565toRGB888(&src, &mutableDst, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        DispatchQueue.main.async {
            self.cgImage = self.imageBuffer?.makeCGImage(cgImageFormat: vImage_CGImageFormat(
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                colorSpace: Unmanaged.passUnretained(CGColorSpaceCreateDeviceRGB()),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                version: 0,
                decode: nil,
                renderingIntent: .defaultIntent
            ))
        }
        readBuffer.removeFirst(readOffset * 2)
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
                writeBuffer = ContiguousArray<UInt16>(repeating: 0, count: w * h)
                imageBuffer = vImage.PixelBuffer<vImage.Interleaved8x3>(width: w, height: h)
                imageBuffer?.withUnsafeVImageBuffer { buf in
                    guard let dataPtr = buf.data else { return }
                    _ = memset(dataPtr, 0, buf.rowBytes * h)
                }
                cgImage = nil
                streamState = .streaming
            }
        }
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard case .streaming = streamState else { return }
        readBuffer.append(data)
        if let region = updateRegion {
            if !decompress() {
                streamState = .error("Decompression failed.")
            } else if writeOffset >= expectedPixels {
                processUpdate(region: region)
                updateRegion = nil // wait for next header
            }
        } else if !parseHeader() {
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
