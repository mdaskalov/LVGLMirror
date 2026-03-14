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
    let LV_MAGIC: UInt16 = 0x564C // LV
    let HEADER_WORDS: Int = 5 // 2(LV) + 2(x) + 2(y) + 2(w) + 2(h)

    @Published var host = "office-th"
    @Published var streamState: LVGLStreamState = .idle
    @Published var cgImage: CGImage?
    @Published var aspectRatio: CGFloat = 1.0

    private var streamingTask: URLSessionDataTask?

    private var (x,y,w,h) = (0,0,0,0)
    private var headerParsed = false

    private var readBuffer: ContiguousArray<UInt16> = []
    private var readOffset = 0  // in words
    private var dataOffset = 0  // in bytes

    private var expectedPixels = 0
    private var writeOffset = 0
    private var writeBuffer: ContiguousArray<UInt16> = []
    private var writeVImageBuffer = vImage_Buffer()

    private var imageBuffer: vImage.PixelBuffer<vImage.Interleaved8x3>?
    
    private var touchTimer: Timer?
    private var touchLastLocation: CGPoint = .zero
    
    var lastRead = Date()

    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private lazy var cgImageFormat = vImage_CGImageFormat(
        bitsPerComponent: 8,
        bitsPerPixel: 24,
        colorSpace: Unmanaged.passUnretained(colorSpace),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        version: 0,
        decode: nil,
        renderingIntent: .defaultIntent
    )

    func startStreaming() {
        stopStreaming()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        guard let url = URL(string: "http://\(host):8881") else { streamState = .error("Invalid host"); return }
        streamingTask = session.dataTask(with: url)
        streamState = .started
        streamingTask?.resume()
    }

    func stopStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        streamState = .error("Invalid response")
        if let response = response as? HTTPURLResponse, let screenSize = response.value(forHTTPHeaderField: "Screen-Size") {
            let parts = screenSize.split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                aspectRatio = CGFloat(w) / CGFloat(h)
                let bufSize = HEADER_WORDS + (w * h)
                readBuffer = ContiguousArray<UInt16>(unsafeUninitializedCapacity: bufSize) { _, count in count = bufSize }
                writeBuffer = ContiguousArray<UInt16>(unsafeUninitializedCapacity: bufSize) { _, count in count = bufSize }
                writeVImageBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: writeBuffer.withUnsafeMutableBytes { $0.baseAddress! }),
                    height: vImagePixelCount(h),
                    width: vImagePixelCount(w),
                    rowBytes: w * MemoryLayout<UInt16>.size
                )
                imageBuffer = vImage.PixelBuffer<vImage.Interleaved8x3>(width: w, height: h)
                imageBuffer?.withUnsafeVImageBuffer { buf in
                    guard let dataPtr = buf.data else { return }
                    _ = memset(dataPtr, 0, buf.rowBytes * h)
                }
                cgImage = nil
                dataOffset = 0
                readOffset = 0
                headerParsed = false
                streamState = .streaming
//                lastRead = Date()
            }
        }
        completionHandler(.allow)
    }
   
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard case .streaming = streamState else { return }
        data.withUnsafeBytes { dataPtr in
            readBuffer.withUnsafeMutableBufferPointer { readBufPtr in
                let readBufferBytes = UnsafeMutableRawPointer(readBufPtr.baseAddress!)
                
                // Append new data
                readBufferBytes.advanced(by: dataOffset).copyMemory(from: dataPtr.baseAddress!, byteCount: dataPtr.count)
                dataOffset += dataPtr.count
                let totalWords = dataOffset / 2
                
//                let now = Date()
//                let delta = Int(now.timeIntervalSince(lastRead) * 1000)
//                let fmt = DateFormatter()
//                fmt.dateFormat = "HH:mm:ss.SSS"
//                print("\(fmt.string(from: now)) read \(data.count) +\(delta)ms")
//                lastRead = now
                
                writeBuffer.withUnsafeMutableBufferPointer { writeBufPtr in
                    while true {
                        if !headerParsed {
                            guard totalWords - readOffset >= HEADER_WORDS else { return }
                            let p = readBufPtr.baseAddress!.advanced(by: readOffset)
                            guard p[0] == LV_MAGIC else { streamState = .error("Out of sync."); return }
                            (x, y, w, h) = (Int(p[1]), Int(p[2]), Int(p[3]), Int(p[4]))
                            writeVImageBuffer.height = vImagePixelCount(h)
                            writeVImageBuffer.width = vImagePixelCount(w)
                            writeVImageBuffer.rowBytes = w * MemoryLayout<UInt16>.size
                            expectedPixels = w * h
                            readOffset += HEADER_WORDS
                            writeOffset = 0
                            headerParsed = true
                        }
                        while readOffset < totalWords && writeOffset < expectedPixels {
                            let p = readBufPtr.baseAddress!.advanced(by: readOffset)
                            let header = p[0]
                            let isRun = (header & 0x8000) != 0
                            let count = Int(header & 0x7FFF) + (isRun ? 2 : 1)
                            let packetSize = 1 + (isRun ? 1 : count)
                            guard readOffset + packetSize <= totalWords else { break }
                            let dst = writeBufPtr.baseAddress!.advanced(by: writeOffset)
                            if isRun {
                                dst.initialize(repeating: p[1], count: count)
                            } else {
                                dst.update(from: p.advanced(by: 1), count: count)
                            }
                            readOffset += packetSize
                            writeOffset += count
                        }

                        guard writeOffset >= expectedPixels else { return }

                        headerParsed = false
                        imageBuffer?.withUnsafeRegionOfInterest(CGRect(x: x, y: y, width: w, height: h)) { roiBuffer in
                            roiBuffer.withUnsafeVImageBuffer { dst in
                                var mutableDst = dst
                                vImageConvert_RGB565toRGB888(&writeVImageBuffer, &mutableDst, vImage_Flags(kvImageNoFlags))
                            }
                        }
                        DispatchQueue.main.async {
                            self.cgImage = self.imageBuffer?.makeCGImage(cgImageFormat: self.cgImageFormat)
                        }
                    }
                }
                if readOffset == totalWords {
                    dataOffset = 0
                } else {
                    let consumedBytes = readOffset * 2
                    let remainingBytes = dataOffset - consumedBytes
                    memmove(readBufferBytes, readBufferBytes.advanced(by: consumedBytes), remainingBytes)
                    dataOffset = remainingBytes
                }
                readOffset = 0
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.invalidateAndCancel()  // release delegate reference
        if let err = error as NSError? {
            streamState = err.code == NSURLErrorCancelled ? .idle : .error(err.localizedDescription)
        } else {
            if case .streaming = streamState { streamState = .idle }
        }
    }
    
    private func sendTouch(at location: CGPoint, touches: Int) {
        guard let url = URL(string: "http://\(host)/lvgl_touch") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "x=\(Int(location.x))&y=\(Int(location.y))&t=\(touches)".data(using: .utf8)
        URLSession.shared.dataTask(with: request).resume()
    }
        
    private func normalizedTouch(at location: CGPoint, in g: GeometryProxy) -> CGPoint {
        let imageWidth = CGFloat(cgImage?.width ?? 0)
        let imageHeight = CGFloat(cgImage?.height ?? 0)
        let rawX = location.x * imageWidth / g.size.width
        let x = min(max(rawX, 0), imageWidth)
        let rawY = location.y * imageHeight / g.size.height
        let y = min(max(rawY, 0), imageHeight)
        return CGPoint(x: x, y: y)
    }
       
    func touchChanged(to location: CGPoint, in g: GeometryProxy) {
        touchLastLocation = normalizedTouch(at: location, in: g)
        guard touchTimer == nil else { return }
        sendTouch(at: touchLastLocation, touches: 1)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sendTouch(at: self.touchLastLocation, touches: 1)
        }
        RunLoop.main.add(timer, forMode: .common)
        touchTimer = timer
    }
    
    func touchEnded(at location: CGPoint, in g: GeometryProxy) {
        touchTimer?.invalidate()
        touchTimer = nil
        sendTouch(at: normalizedTouch(at: location, in: g), touches: 0)
    }
}
