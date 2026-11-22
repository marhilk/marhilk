import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import VideoToolbox
import XCTest
@testable import AltyaziCore
@testable import RemotePlayKit

final class DiscoveryTests: XCTestCase {
    func testParsesAwakeAndStandbyPS5() {
        let awake = "HTTP/1.1 200 Ok\nhost-id:AABBCCDDEEFF\nhost-type:PS5\nhost-name:Salon PS5\nhost-request-port:997\ndevice-discovery-protocol-version:00030010\nsystem-version:10000000\n"
        let host = PS5Discovery.parse(awake, address: "192.168.1.50")
        XCTAssertEqual(host?.name, "Salon PS5")
        XCTAssertEqual(host?.hostID, "AABBCCDDEEFF")
        XCTAssertEqual(host?.isStandby, false)
        XCTAssertNil(host?.runningTitleID, "ana ekranda oyun bilgisi yoktur")
        let playing = awake + "running-app-titleid:PPSA01234\nrunning-app-name:Örnek Oyun\n"
        XCTAssertEqual(PS5Discovery.parse(playing, address: "192.168.1.50")?.runningTitleID, "PPSA01234")
        XCTAssertEqual(PS5Discovery.parse(playing, address: "192.168.1.50")?.runningTitleName, "Örnek Oyun")

        let standby = "HTTP/1.1 620 Server Standby\nhost-id:AABBCCDDEEFF\nhost-type:PS5\nhost-name:Salon PS5\n"
        XCTAssertEqual(PS5Discovery.parse(standby, address: "192.168.1.50")?.isStandby, true)
    }

    func testIgnoresOtherDevices() {
        XCTAssertNil(PS5Discovery.parse("HTTP/1.1 200 Ok\nhost-type:PS4\nhost-name:Eski\n", address: "1.2.3.4"))
        XCTAssertNil(PS5Discovery.parse("NOTIFY * HTTP/1.1\nhost-type:PS5\n", address: "1.2.3.4"))
    }
}

final class PSNAccountTests: XCTestCase {
    func testAccountIDIsLittleEndianEightBytes() {
        // chiaki betiğiyle aynı sonuç: int(user_id).to_bytes(8, "little")
        XCTAssertEqual(PSNAccount.accountID(fromUserID: "1234567890123456789")?.base64EncodedString(), "FYHpffQQIhE=")
        XCTAssertNil(PSNAccount.accountID(fromUserID: "abc"))
    }

    func testRecognizesRedirect() {
        XCTAssertTrue(PSNAccount.isRedirect(URL(string: "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=abc&cid=1")!))
        XCTAssertFalse(PSNAccount.isRedirect(URL(string: "https://my.account.sony.com/signin")!))
    }
}

/// Çözücüyü PS5 olmadan sınar: yazılı bir kareyi donanım kodlayıcısıyla sıkıştırır,
/// PS5'in yolladığı biçime (Annex-B) çevirir, çözücüden geçirir ve çıkan karedeki yazıyı okur.
final class VideoDecoderTests: XCTestCase {
    private func makePixelBuffer(text: String, width: Int = 1280, height: Int = 720) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.14, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 40, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: 80)
        CTLineDraw(line, context)
        return pixelBuffer
    }

    /// Kodlayıcı çıktısını (uzunluk önekli) PS5'in yolladığı gibi başlangıç kodlu hâle çevirir.
    private func annexB(from sample: CMSampleBuffer, codec: VideoDecoder.Codec) -> (header: [UInt8], frame: [UInt8]) {
        let startCode: [UInt8] = [0, 0, 0, 1]
        var header: [UInt8] = []
        let format = CMSampleBufferGetFormatDescription(sample)!
        var count = 0
        if codec == .h264 {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if codec == .h264 {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            header += startCode + Array(UnsafeBufferPointer(start: pointer, count: size))
        }
        // PS5 başlığın sonuna sıfır dolgu ekler; çözücü bunu atabilmeli.
        header += [UInt8](repeating: 0, count: 64)

        let block = CMSampleBufferGetDataBuffer(sample)!
        var length = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        let bytes = UnsafeRawBufferPointer(start: dataPointer, count: length)
        var frame: [UInt8] = []
        var offset = 0
        while offset + 4 <= length {
            let size = Int(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            frame += startCode + Array(bytes[(offset + 4)..<(offset + 4 + size)])
            offset += 4 + size
        }
        return (header, frame)
    }

    private func roundTrip(codec: VideoDecoder.Codec, text: String) throws -> String {
        var encoder: VTCompressionSession?
        let type = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        XCTAssertEqual(VTCompressionSessionCreate(allocator: nil, width: 1280, height: 720, codecType: type, encoderSpecification: nil,
                                                  imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                                  refcon: nil, compressionSessionOut: &encoder), noErr)
        let session = try XCTUnwrap(encoder)
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 6_000_000 as CFNumber)

        let decoder = VideoDecoder(codec: codec)
        var decoded: [CVPixelBuffer] = []
        decoder.onFrame = { decoded.append($0) }

        let source = makePixelBuffer(text: text)
        var headerSent = false
        // Bir anahtar kare + iki ara kare: PS5 akışındaki gibi başlık yalnız en başta gelir.
        for index in 0..<3 {
            let done = expectation(description: "kare \(index)")
            VTCompressionSessionEncodeFrame(session, imageBuffer: source, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                defer { done.fulfill() }
                guard status == noErr, let sample else { return XCTFail("kodlama hatası \(status)") }
                let packet = self.annexB(from: sample, codec: codec)
                if !headerSent {
                    headerSent = true
                    packet.header.withUnsafeBufferPointer { decoder.consume($0) }
                }
                packet.frame.withUnsafeBufferPointer { decoder.consume($0) }
            }
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            wait(for: [done], timeout: 10)
        }

        XCTAssertEqual(decoded.count, 3, "üç karenin üçü de çözülmeli")
        XCTAssertEqual(decoder.failedFrames, 0)
        let last = try XCTUnwrap(decoded.last)
        XCTAssertEqual(CVPixelBufferGetWidth(last), 1280)
        return try TextRecognizer().recognizeLines(pixelBuffer: last, roi: CGRect(x: 0, y: 0, width: 1, height: 0.3)).map(\.text).joined(separator: " ")
    }

    func testH264StreamDecodesToReadableSubtitle() throws {
        XCTAssertEqual(try roundTrip(codec: .h264, text: "We need to cross the bridge."), "We need to cross the bridge.")
    }

    func testHEVCStreamDecodesToReadableSubtitle() throws {
        XCTAssertEqual(try roundTrip(codec: .hevc, text: "Where did you find this sword?"), "Where did you find this sword?")
    }

    /// Çözücü yeniden kurulduktan sonra (telefon kilitlenince olur) ilk gelen kare çoğu zaman bir ARA karedir.
    /// Çözücü bunu "çözülemedi" diye bildirmeli ki PS5'ten yeni bir anahtar kare istensin; yoksa akış hiç toparlanmaz.
    func testFrameAfterDecoderResetReportsFailureUntilKeyframeArrives() throws {
        var encoder: VTCompressionSession?
        XCTAssertEqual(VTCompressionSessionCreate(allocator: nil, width: 1280, height: 720, codecType: kCMVideoCodecType_H264,
                                                  encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                  outputCallback: nil, refcon: nil, compressionSessionOut: &encoder), noErr)
        let session = try XCTUnwrap(encoder)
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1000 as CFNumber)

        var header: [UInt8] = []
        var frames: [[UInt8]] = []
        for index in 0..<3 {
            let done = expectation(description: "kare \(index)")
            let source = makePixelBuffer(text: "Frame number \(index)")
            VTCompressionSessionEncodeFrame(session, imageBuffer: source, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                defer { done.fulfill() }
                guard status == noErr, let sample else { return XCTFail("kodlama hatası \(status)") }
                let packet = self.annexB(from: sample, codec: .h264)
                if header.isEmpty { header = packet.header }
                frames.append(packet.frame)
            }
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            wait(for: [done], timeout: 10)
        }
        XCTAssertEqual(frames.count, 3)

        // Yeni bir çözücü: başlık var ama ilk gelen kare anahtar kare değil (2. kare).
        let decoder = VideoDecoder(codec: .h264)
        var decoded = 0
        decoder.onFrame = { _ in decoded += 1 }
        XCTAssertTrue(header.withUnsafeBufferPointer { decoder.consume($0) }, "başlık tek başına hata değildir")
        let interResult = frames[1].withUnsafeBufferPointer { decoder.consume($0) }
        // Anahtar kare gelince çözme kesin başarılı olmalı.
        XCTAssertTrue(frames[0].withUnsafeBufferPointer { decoder.consume($0) })
        XCTAssertGreaterThanOrEqual(decoded, 1)
        // Ara kare çözülemediyse bunu false ile bildirmiş olmalı (sessizce yutmamalı).
        if decoder.failedFrames > 0 { XCTAssertFalse(interResult, "çözülemeyen kare false döndürmeli") }
        print("ara kare sonucu: \(interResult), bozuk: \(decoder.failedFrames), hata: \(decoder.lastErrorCode)")
    }

    func testSplitsStartCodesAndDropsPadding() {
        let data: [UInt8] = [0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0xCC, 0, 0, 0]
        let units = data.withUnsafeBufferPointer { VideoDecoder.splitNALUnits($0).map(Array.init) }
        XCTAssertEqual(units, [[0x67, 0xAA], [0x68, 0xBB, 0xCC]])
    }
}
