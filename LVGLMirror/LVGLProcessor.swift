//
//  LVGLProcessor.swift
//  LVGLMirror
//
//  Created by Milko Daskalov on 02.01.26.
//

import Accelerate
import SwiftUI

// Uses enum because LVGLProcessor can only process
enum LVGLProcessor {
    private struct LVGLUpdate: Codable, Sendable {
        let x1, y1, x2, y2: Int
        let b64: String?
    }

    static func process(jsonPayload: Data, backingStore: NSBitmapImageRep) -> NSImage? {
        guard let update = try? JSONDecoder().decode(LVGLUpdate.self, from: jsonPayload),
              let b64 = update.b64,
              let rawImgData = Data(base64Encoded: b64) else {
            return nil
        }
        
        let width  = update.x2 - update.x1 + 1
        let height = update.y2 - update.y1 + 1

        guard width > 0, height > 0, let destBasePtr = backingStore.bitmapData else { return nil }
        
        let destStrideBytes = backingStore.bytesPerRow                    // full bitmap stride (width * 3 + any padding, usually exact)
        let destOffsetBytes = update.y1 * destStrideBytes + update.x1 * 3 // byte offset to top-left of update region
        
        var srcBuffer = vImage_Buffer()
        rawImgData.withUnsafeBytes { rawPtr in
            srcBuffer.data     = UnsafeMutableRawPointer(mutating: rawPtr.baseAddress)
            srcBuffer.width    = vImagePixelCount(width)
            srcBuffer.height   = vImagePixelCount(height)
            srcBuffer.rowBytes = width * 2   // tight packing assumed
        }
        
        var destBuffer = vImage_Buffer()
        destBuffer.data     = UnsafeMutableRawPointer(destBasePtr).advanced(by: destOffsetBytes)
        destBuffer.width    = vImagePixelCount(width)
        destBuffer.height   = vImagePixelCount(height)
        destBuffer.rowBytes = destStrideBytes
        
        let err = vImageConvert_RGB565toRGB888(&srcBuffer, &destBuffer, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { return nil }
        
        let finalImage = NSImage(size: NSSize(width: backingStore.pixelsWide, height: backingStore.pixelsHigh))
        finalImage.addRepresentation(backingStore)
        return finalImage
    }

}
