import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// PS5'ten gelen sıkıştırılmış görüntüyü (H.264 ya da HEVC, Annex-B) donanım
/// çözücüsüyle karelere çevirir. Tek iş parçacığından beslenmelidir.
public final class VideoDecoder {
    public enum Codec: Sendable { case h264, hevc }

    /// Çözülen her kare için çağrılır (çözücünün iş parçacığında).
    public var onFrame: ((CVPixelBuffer) -> Void)?
    public private(set) var decodedFrames = 0
    public private(set) var failedFrames = 0
    /// Çözücü oturumunun yeniden kurulma sayısı (iOS, uygulama arka plana geçince oturumu geçersiz kılar).
    public private(set) var sessionRebuilds = 0
    /// Son çözme hatasının kodu (teşhis için).
    public private(set) var lastErrorCode: OSStatus = 0

    private let codec: Codec
    private var parameterSets: [UInt8: [UInt8]] = [:]   // NAL türü → içerik
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    public init(codec: Codec) {
        self.codec = codec
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Bir parça Annex-B verisi: akış başlığı (parametre kümeleri) ya da bir kare.
    /// - Returns: kare çözülemediyse `false` (çağıran PS5'ten yeni bir anahtar kare istemelidir).
    @discardableResult
    public func consume(_ data: UnsafeBufferPointer<UInt8>) -> Bool {
        var frame: [UInt8] = []
        var parametersChanged = false

        for nal in Self.splitNALUnits(data) {
            guard let first = nal.first else { continue }
            let type = nalType(first)
            if isParameterSet(type) {
                let bytes = Array(nal)
                if parameterSets[type] != bytes {
                    parameterSets[type] = bytes
                    parametersChanged = true
                }
            } else if isPicture(type) {
                // Çözücü, başlangıç kodu yerine 4 baytlık uzunluk bekler.
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
                frame.append(contentsOf: nal)
            }
        }

        if parametersChanged { rebuildSession() }
        guard !frame.isEmpty else { return true }
        if session == nil { rebuildSession() }   // önceki oturum geçersizleşmiş olabilir
        guard let session, let format else {
            failedFrames += 1
            return false
        }
        let status = decode(frame, session: session, format: format)
        if status == kVTInvalidSessionErr {
            // iOS oturumu geri aldı (uygulama arka plana geçince olur): yeniden kur.
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            sessionRebuilds += 1
            rebuildSession()
        }
        // Yeni kurulan çözücü ancak bir anahtar kareyle başlayabilir; ara kareler hata verir.
        // false dönmek, PS5'ten anahtar kare istenmesini sağlar.
        return status == noErr
    }

    // MARK: - NAL ayrıştırma

    /// Veriyi 00 00 01 başlangıç kodlarından böler; sondaki sıfır dolguyu atar.
    static func splitNALUnits(_ data: UnsafeBufferPointer<UInt8>) -> [Slice<UnsafeBufferPointer<UInt8>>] {
        var units: [Slice<UnsafeBufferPointer<UInt8>>] = []
        var starts: [(code: Int, payload: Int)] = []
        var index = 0
        let count = data.count
        while index + 2 < count {
            if data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 {
                starts.append((index, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        for (position, start) in starts.enumerated() {
            var end = position + 1 < starts.count ? starts[position + 1].code : count
            while end > start.payload, data[end - 1] == 0 { end -= 1 }
            if end > start.payload { units.append(data[start.payload..<end]) }
        }
        return units
    }

    private func nalType(_ header: UInt8) -> UInt8 {
        codec == .h264 ? header & 0x1F : (header >> 1) & 0x3F
    }

    private func isParameterSet(_ type: UInt8) -> Bool {
        codec == .h264 ? (type == 7 || type == 8) : (32...34).contains(type)
    }

    private func isPicture(_ type: UInt8) -> Bool {
        codec == .h264 ? (1...5).contains(type) : type <= 21
    }

    // MARK: - Çözücü

    private func rebuildSession() {
        let ordered: [[UInt8]]
        switch codec {
        case .h264:
            guard let sps = parameterSets[7], let pps = parameterSets[8] else { return }
            ordered = [sps, pps]
        case .hevc:
            guard let vps = parameterSets[32], let sps = parameterSets[33], let pps = parameterSets[34] else { return }
            ordered = [vps, sps, pps]
        }

        var description: CMVideoFormatDescription?
        let status = withParameterSetPointers(ordered) { pointers, sizes -> OSStatus in
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return }

        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = description

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var created: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
        if createStatus == noErr { session = created }
    }

    private func withParameterSetPointers<R>(_ sets: [[UInt8]], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        // Göstericilerin çağrı boyunca geçerli kalması için tek bir bitişik arabellek kullanılır.
        let joined = sets.flatMap { $0 }
        return joined.withUnsafeBufferPointer { buffer in
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for set in sets {
                pointers.append(buffer.baseAddress! + offset)
                offset += set.count
            }
            return body(pointers, sets.map(\.count))
        }
    }

    @discardableResult
    private func decode(_ frame: [UInt8], session: VTDecompressionSession, format: CMVideoFormatDescription) -> OSStatus {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: frame.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            CMBlockBufferReplaceDataBytes(with: frame, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.count) == noErr
        else {
            failedFrames += 1
            return -1
        }

        var sample: CMSampleBuffer?
        var size = frame.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample
        else {
            failedFrames += 1
            return -1
        }

        // Bayrak verilmediği için çözme eşzamanlıdır: geri çağrı bu çağrı dönmeden gelir.
        // Hata iki yoldan gelebilir: çağrının dönüş değeri ya da geri çağrının durumu.
        var callbackStatus: OSStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            if status == noErr, let imageBuffer {
                self.decodedFrames += 1
                self.onFrame?(imageBuffer)
            } else {
                callbackStatus = status == noErr ? -1 : status
            }
        }
        let result = status != noErr ? status : callbackStatus
        if result != noErr {
            failedFrames += 1
            lastErrorCode = result
        }
        return result
    }
}
