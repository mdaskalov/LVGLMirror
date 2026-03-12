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

    private var (x,y,w,h) = (0,0,0,0)
    private var headerParsed = false

    private var readCursor: Int = 0
    private var readOffset = 0
    private var readBuffer = Data()

    private var expectedPixels = 0
    private var writeOffset = 0
    private var writeBuffer: ContiguousArray<UInt16> = []
    private var writeVImageBuffer = vImage_Buffer()

    private var imageBuffer: vImage.PixelBuffer<vImage.Interleaved8x3>?
    
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

    func startStreaming(from url: URL) {
        stopStreaming()  // cancel + invalidate old session
        readBuffer.removeAll()
        readCursor = 0
        readOffset = 0
        headerParsed = false
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
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
                writeBuffer = ContiguousArray<UInt16>(unsafeUninitializedCapacity: w * h) { _, count in count = w * h }
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
                streamState = .streaming
                lastRead = Date()
            }
        }
        completionHandler(.allow)
    }
   
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let LV_MAGIC: UInt16 = 0x564C // LV
        let HEADER_WORDS: Int = 5 // 2(LV) + 2(x) + 2(y) + 2(w) + 2(h)

        guard case .streaming = streamState else { return }
        readBuffer.append(data)
        
//        let now = Date()
//        let delta = Int(now.timeIntervalSince(lastRead) * 1000)
//        let fmt = DateFormatter()
//        fmt.dateFormat = "HH:mm:ss.SSS"
//        print("\(fmt.string(from: now)) read \(data.count) +\(delta)ms")
//        lastRead = now

        while true {
            var didCompleteFrame = false
            readBuffer.withUnsafeBytes { readBufPtr in
                let totalWords = readBuffer.count / 2
                let available = totalWords - (readCursor/2)
                guard let src = readBufPtr.baseAddress?.bindMemory(to: UInt16.self, capacity: totalWords).advanced(by: readCursor/2) else { return }
                if !headerParsed {
                    guard available >= HEADER_WORDS else { return }
                    guard src[0] == LV_MAGIC else { streamState = .error("Out of sync."); return }
                    (x, y, w, h) = (Int(src[1]), Int(src[2]), Int(src[3]), Int(src[4]))
                    writeVImageBuffer.height = vImagePixelCount(h)
                    writeVImageBuffer.width = vImagePixelCount(w)
                    writeVImageBuffer.rowBytes = w * MemoryLayout<UInt16>.size
                    expectedPixels = w * h
                    readOffset = HEADER_WORDS
                    writeOffset = 0
                    headerParsed = true
                }
                writeBuffer.withUnsafeMutableBufferPointer { writeBufPtr in
                    while readOffset < available && writeOffset < expectedPixels {
                        let header = src[readOffset]
                        let isRun = (header & 0x8000) != 0
                        let count = Int(header & 0x7FFF) + (isRun ? 2 : 1)
                        guard readOffset + 1 + (isRun ? 1 : count) <= available else { break }
                        let dst = writeBufPtr.baseAddress!.advanced(by: writeOffset)
                        if isRun {
                            dst.initialize(repeating: src[readOffset + 1], count: count)
                            readOffset += 2
                        } else {
                            dst.update(from: src.advanced(by: readOffset + 1), count: count)
                            readOffset += 1 + count
                        }
                        writeOffset += count
                    }
                    if writeOffset >= expectedPixels {
                        didCompleteFrame = true
                        headerParsed = false
                        readCursor += readOffset * 2
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
            }
            guard didCompleteFrame else { return }  // wait for more data
        }
            
        print("bufferSize: \(readBuffer.count)")

        if readCursor == readBuffer.count {
            readBuffer.removeAll(keepingCapacity: true)
            readCursor = 0
            readOffset = 0
        } else {
            print("remained: \(readBuffer.count - readCursor) bytes")
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
}
