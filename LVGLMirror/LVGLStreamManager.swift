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

    private var readOffset = 0
    private var readBuffer = Data()

    private var expectedPixels = 0
    private var writeOffset = 0
    private var writeBuffer: ContiguousArray<UInt16> = []

    private var imageBuffer: vImage.PixelBuffer<vImage.Interleaved8x3>?

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
        let LV_MAGIC: UInt16 = 0x564C // LV
        let HEADER_WORDS: Int = 5 // 2(LV) + 2(x) + 2(y) + 2(w) + 2(h)

        guard case .streaming = streamState else { return }
        readBuffer.append(data)
        var totalConsumed = 0
        while true {
            let available = (readBuffer.count - totalConsumed) / 2  // words available from cursor
            if !headerParsed {
                guard available >= HEADER_WORDS else { break }

                readBuffer.withUnsafeBytes { rawPtr in
                    let words = rawPtr.baseAddress!
                        .advanced(by: totalConsumed)
                        .assumingMemoryBound(to: UInt16.self)
                    let magic = words[0]
                    guard magic == LV_MAGIC else { streamState = .error("Out of sync."); return }
                    (x, y, w, h) = (Int(words[1]), Int(words[2]), Int(words[3]), Int(words[4]))
                }
                expectedPixels = w * h
                readOffset = HEADER_WORDS
                writeOffset = 0
                headerParsed = true
            }
            var didCompleteFrame = false
            readBuffer.withUnsafeBytes { rawPtr in
                let srcBase = rawPtr.baseAddress!
                    .advanced(by: totalConsumed)
                    .assumingMemoryBound(to: UInt16.self)
                let frameWords = (readBuffer.count - totalConsumed) / 2
                writeBuffer.withUnsafeMutableBufferPointer { writeBuf in
                    while readOffset < frameWords && writeOffset < expectedPixels {
                        let header = srcBase[readOffset]
                        let isRun = (header & 0x8000) != 0
                        let count = Int(header & 0x7FFF) + (isRun ? 2 : 1)
                        guard readOffset + 1 + (isRun ? 1 : count) <= frameWords else { break }
                        let dst = writeBuf.baseAddress!.advanced(by: writeOffset)
                        if isRun {
                            dst.initialize(repeating: srcBase[readOffset + 1], count: count)
                            readOffset += 2
                        } else {
                            dst.update(from: srcBase.advanced(by: readOffset + 1), count: count)
                            readOffset += 1 + count
                        }
                        writeOffset += count
                    }

                    if writeOffset >= expectedPixels {
                        didCompleteFrame = true
                        headerParsed = false
                        totalConsumed += readOffset * 2
                    }
                }
            }
            guard didCompleteFrame else { break }  // wait for more data
            imageBuffer?.withUnsafeRegionOfInterest(CGRect(x: x, y: y, width: w, height: h)) { roiBuffer in
                roiBuffer.withUnsafeVImageBuffer { dst in
                    var src = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: writeBuffer.withUnsafeMutableBytes { $0.baseAddress! }),
                        height: vImagePixelCount(h),
                        width: vImagePixelCount(w),
                        rowBytes: w * MemoryLayout<UInt16>.size
                    )
                    var mutableDst = dst
                    vImageConvert_RGB565toRGB888(&src, &mutableDst, vImage_Flags(kvImageNoFlags))
                }
            }
            DispatchQueue.main.async {
                self.cgImage = self.imageBuffer?.makeCGImage(cgImageFormat: self.cgImageFormat)
            }
        }
        if totalConsumed == readBuffer.count {
            readBuffer.removeAll(keepingCapacity: true)
        } else if totalConsumed > 0 {
            //print("removed \(totalConsumed) at front of \(readBuffer.count)")
            readBuffer.removeSubrange(0..<totalConsumed)
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
