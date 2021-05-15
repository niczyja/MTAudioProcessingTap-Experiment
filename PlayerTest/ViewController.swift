//
//  ViewController.swift
//  PlayerTest
//
//  Created by Maciej Sienkiewicz on 10/05/2021.
//

import UIKit
import AVFoundation
import MediaToolbox
import Accelerate

class ViewController: UIViewController {

    class TapWrapper {
        weak var content: AnyObject?
        
        init(content: AnyObject) {
            self.content = content
        }
        
        deinit {
            print("tap wrapper deinit")
        }
    }
    
    var skipSilencesEnabled: Bool = false
    var voiceBoostEnabled: Bool = true
    
    @IBOutlet weak var picker: UIPickerView!
    @IBOutlet weak var rate: UILabel!
    
    var player: AVPlayer?
    var playerItem: AVPlayerItem! = nil
    
    var tracksObserver: NSKeyValueObservation? = nil
    var statusObserver: NSKeyValueObservation? = nil
    var rateObserver: NSKeyValueObservation? = nil

    var audioDescription: AudioStreamBasicDescription? = nil
    var forwardDCT: vDSP.DCT!
    var inverseDCT: vDSP.DCT!
    var forwardDCT_PreProcessed: [Float]!
    var forwardDCT_PostProcessed: [Float]!
    var inverseDCT_Result: [Float]!

    var bufferCount: Int = 1
    var bufferCumulated = [Float]()
    var bufferAmplitudes = [Float]()
    
    
    let podcasts: [String: URL] = [
        "MP3 long no chapters": URL(string: "https://traffic.libsyn.com/secure/joeroganexp/p1109.mp3")!,
        "MP3 short no chapters": URL(string: "https://traffic.libsyn.com/secure/tuingles/Welcome_To_Tu_Ingles.mp3")!,
        "MP3 long chapters": URL(string: "https://traffic.libsyn.com/secure/daringfireball/thetalkshow-313-glenn-fleishman.mp3")!,
        "MP4 short no chapters": URL(string: "https://sec.ch9.ms/ch9/84ef/94552aa8-8d15-4e55-abc1-bbb1136b84ef/ZeroTrustforIoT.mp4")!,
        "MP4 low bitrate": URL(string: "http://www.allaboutsymbian.com/downloads/smartphones-show/ss343.mp4")!
    ]
    
    

    override func viewDidLoad() {
        super.viewDidLoad()

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
        } catch {
            print(error)
        }
        
        picker.dataSource = self
        picker.delegate = self
    }

    func playItem(at url: URL) {
        print(url)
        
        playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: self.playerItem)

        tracksObserver = playerItem.observe(\AVPlayerItem.tracks) { [unowned self] (item, change) in
            print("Item tracks:", item.tracks)
            print("Asset tracks:", item.asset.tracks)
            
            self.installTap(at: self.playerItem)
        }
        
        statusObserver = playerItem.observe(\AVPlayerItem.status, changeHandler: { [unowned self] (item, change) in
            print("Item status change:", item.status.rawValue)
            
            if item.status == .readyToPlay {
                self.player?.play()
            }
        })
        
        rateObserver = player?.observe(\AVPlayer.rate, changeHandler: { [unowned self] (player, change) in
            DispatchQueue.main.async {
                UIView.animate(withDuration: 0.1) {
                    self.rate.text = String(format: "%0.2f", player.rate)
                }
            }
        })
    }

    func stop() {
        player?.pause()
        tracksObserver = nil
        statusObserver = nil
        rateObserver = nil
        playerItem = nil
        player = nil
    }

    func installTap(at item: AVPlayerItem) {
        let tapWrapper = TapWrapper(content: self)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(tapWrapper).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess)
        var tap: Unmanaged<MTAudioProcessingTap>?
        let error = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)

        guard error == noErr else {
            print(error)
            return
        }
        
        let audioTrack = item.asset.tracks(withMediaType: AVMediaType.audio).first!
        let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        inputParams.audioTimePitchAlgorithm = .lowQualityZeroLatency
        inputParams.audioTapProcessor = tap?.takeRetainedValue()
        
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParams]
        
        item.audioMix = audioMix
    }
    
    let tapInit: MTAudioProcessingTapInitCallback = { (tap, clientInfo, tapStorageOut) in
        print("TapInit", tap, clientInfo as Any, tapStorageOut)

        tapStorageOut.pointee = clientInfo
    }
    
    let tapFinalize: MTAudioProcessingTapFinalizeCallback = { (tap) in
        print("TapFinalize", tap)
        
        Unmanaged<TapWrapper>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
    }
    
    let tapPrepare: MTAudioProcessingTapPrepareCallback = { (tap, itemCount, basicDescription) in
        print("TapPrepare", tap, itemCount, basicDescription)
        
        let selfVC = Unmanaged<TapWrapper>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().content as! ViewController
        selfVC.audioDescription = AudioStreamBasicDescription(mSampleRate: basicDescription.pointee.mSampleRate,
                                                              mFormatID: basicDescription.pointee.mFormatID,
                                                              mFormatFlags: basicDescription.pointee.mFormatFlags,
                                                              mBytesPerPacket: basicDescription.pointee.mBytesPerPacket,
                                                              mFramesPerPacket: basicDescription.pointee.mFramesPerPacket,
                                                              mBytesPerFrame: basicDescription.pointee.mBytesPerFrame,
                                                              mChannelsPerFrame: basicDescription.pointee.mChannelsPerFrame,
                                                              mBitsPerChannel: basicDescription.pointee.mBitsPerChannel,
                                                              mReserved: basicDescription.pointee.mReserved)

        selfVC.forwardDCT = vDSP.DCT(count: itemCount, transformType: .II)
        selfVC.inverseDCT = vDSP.DCT(count: itemCount, transformType: .III)
        selfVC.forwardDCT_PreProcessed = [Float](repeating: 0, count: itemCount)
        selfVC.forwardDCT_PostProcessed = [Float](repeating: 0, count: itemCount)
        selfVC.inverseDCT_Result = [Float](repeating: 0, count: itemCount)
    }
    
    let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { (tap) in
        print("TapUnprepare", tap)
    }
    
    let tapProcess: MTAudioProcessingTapProcessCallback = { (tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut) in
        print("TapProcess", tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut)
        
        numberFramesOut.pointee = 4096
        let forwardDCT = vDSP.DCT(count: 4096, transformType: .II)
        let inverseDCT = vDSP.DCT(count: 4096, transformType: .III)

        let error = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
        guard error == noErr else {
            print(error)
            return
        }
        
        let selfVC = Unmanaged<TapWrapper>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().content as! ViewController
        guard selfVC.audioDescription != nil else {
            print("no audio description")
            return
        }
        
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferListInOut)
        for buffer in ablPointer {
            var bufferDataPtr: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
            let bufferDataValue = bufferDataPtr.baseAddress!
            let bufferDataValueArray = stride(from: 0,
                                              to: Int(numberFrames),
                                              by: Int(selfVC.audioDescription!.mChannelsPerFrame)).map { bufferDataValue[$0] }

            // skip silences
            if selfVC.skipSilencesEnabled {
                selfVC.bufferCumulated += bufferDataValueArray
                if selfVC.bufferCount == 32 {
                    let reduced = selfVC.bufferCumulated.map { $0 * $0 }.reduce(0, +)
                    let rms = sqrt(reduced / Float(numberFrames * selfVC.bufferCount))
                    let amplitude = 20 * log10(rms)

                    selfVC.bufferAmplitudes.append(amplitude)
                    let maxAmp = selfVC.bufferAmplitudes.max()!
                    let amp = amplitude < -30.0 ? -30.0 : amplitude

                    if selfVC.playerItem.canPlayFastForward {
                        let newRate = 1.0 + (maxAmp - amp) * 0.01
                        if abs(selfVC.player?.rate ?? 1.0 - newRate) > 0.1 {
                            selfVC.player?.rate = 1.0 + (maxAmp - amp) * 0.01
                        }
                    } else {
                        selfVC.player?.rate = 1.0
                    }

                    selfVC.bufferCumulated = []
                    selfVC.bufferCount = 0
                }
                selfVC.bufferCount += 1

                break
            }

            if selfVC.voiceBoostEnabled {

//                selfVC.forwardDCT.transform(bufferDataValueArray, result: &selfVC.forwardDCT_PreProcessed)
                var forwardDCT_PreProcessed = [Float](repeating: 0, count: numberFrames)
                forwardDCT?.transform(bufferDataValueArray, result: &forwardDCT_PreProcessed)
                
//                let forwardDCT_PreProcessed = performFFT(dataPointer: bufferDataPtr, frameCount: numberFrames)
                let multiplier = interpolatedVectorFrom(magnitudes:  [0,   0,   1,   1,   1,    1,    0,    0],
                                                        indices:     [0, 290, 300, 380, 390, 1024, 2048, 4096],
                                                        count: numberFrames)
                var forwardDCT_PostProcessed = [Float](repeating: 0, count: numberFrames)
                vDSP.multiply(multiplier, forwardDCT_PreProcessed, result: &forwardDCT_PostProcessed)
                selfVC.inverseDCT.transform(forwardDCT_PostProcessed, result: &bufferDataPtr)
                
                
                
//                for i in 0..<numberFrames {
//                    bufferDataPtr[i] = selfVC.inverseDCT_Result[i]
//                }
                
                
                //  UnsafeMutableRawPointer
//                selfVC.inverseDCT_Result.withUnsafeMutableBytes { pointer in
//                    buffer.mData = pointer.baseAddress
//                }
                
//                selfVC.inverseDCT_Result.withUnsafeMutableBufferPointer { pointer in
//                    bufferDataPtr = pointer
//                }
                
//                bufferDataValueArray = Array(selfVC.inverseDCT_Result.prefix(bufferDataValueArray.count))
            }
            
            // voice boost
//                let FftResult = performFFT(dataPointer: bufferDataPtr, frameCount: numberFrames)
//                let frequency = estimateFrequency(FftBuffer: FftResult,
//                                                  frameCount: numberFrames,
//                                                  sampleRate: selfVC.audioDescription!.mSampleRate)
        }
        
        
        
//        // Multiplies the frequency-domain representation of `input` by
//        // `dctMultiplier`, and returns the temporal-domain representation
//        // of the product.
//        func apply(dctMultiplier: [Float], toInput input: [Float]) -> [Float] {
//            // Perform forward DCT.
//            forwardDCT?.transform(input,
//                                  result: &forwardDCT_PreProcessed)
//            // Multiply frequency-domain data by `dctMultiplier`.
//            vDSP.multiply(dctMultiplier,
//                          forwardDCT_PreProcessed,
//                          result: &forwardDCT_PostProcessed)
//
//            // Perform inverse DCT.
//            inverseDCT?.transform(forwardDCT_PostProcessed,
//                                  result: &inverseDCT_Result)
//
//            // In-place scale inverse DCT result by n / 2.
//            // Output samples are now in range -1...+1
//            vDSP.divide(inverseDCT_Result,
//                        Float(sampleCount / 2),
//                        result: &inverseDCT_Result)
//
//            return inverseDCT_Result
//        }

        
            
    }
    
    static func scaledPower(power: Float) -> Float {
        guard power.isFinite else { return 0.0 }
        let minDb: Float = -80.0 // -160?
        if power < minDb {
            return 0.0
        } else if power >= 1.0 {
            return 1.0
        } else {
            return (abs(minDb) - abs(power)) / abs(minDb)
        }
    }
    
    static func performFFT(dataPointer: UnsafeMutableBufferPointer<Float>, frameCount: Int, isNormalized: Bool = false) -> [Float] {
        let log2n = UInt(round(log2(Double(frameCount))))
        let bufferSizePOT = Int(1 << log2n)
        let inputCount = bufferSizePOT / 2
        let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2))
        
        var realp = [Float](repeating: 0, count: inputCount)
        var imagp = [Float](repeating: 0, count: inputCount)
        
        return realp.withUnsafeMutableBufferPointer { realPointer in
            imagp.withUnsafeMutableBufferPointer { imagPointer in
                var output = DSPSplitComplex(realp: realPointer.baseAddress!,
                                             imagp: imagPointer.baseAddress!)
                
                let windowSize = bufferSizePOT
                var transferBuffer = [Float](repeating: 0, count: windowSize)
                var window = [Float](repeating: 0, count: windowSize)
                
                // Hann windowing to reduce the frequency leakage
                vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))
                vDSP_vmul(dataPointer.baseAddress!, 1, window,
                          1, &transferBuffer, 1, vDSP_Length(windowSize))
                
                // Transforming the [Float] buffer into a UnsafePointer<Float> object for the vDSP_ctoz method
                // And then pack the input into the complex buffer (output)
                transferBuffer.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                           capacity: transferBuffer.count) {
                        vDSP_ctoz($0, 2, &output, 1, vDSP_Length(inputCount))
                    }
                }
                
                // Perform the FFT
                vDSP_fft_zrip(fftSetup!, &output, 1, log2n, FFTDirection(FFT_FORWARD))
                
                var magnitudes = [Float](repeating: 0.0, count: inputCount)
                vDSP_zvmags(&output, 1, &magnitudes, 1, vDSP_Length(inputCount))
                
                var scaledMagnitudes = [Float](repeating: 0.0, count: inputCount)
                
                // Scale appropriate to the algorithm - results in strictly negative amplitude values (tested against Ableton Live's Spectrum Analyzer)
                var scaleMultiplier = [Float(1.0 / Double(frameCount))]
                
                if isNormalized {
                    // Normalising
                    scaleMultiplier = [1.0 / (magnitudes.max() ?? 1.0)]
                }
                
                vDSP_vsmul(&magnitudes,
                           1,
                           &scaleMultiplier,
                           &scaledMagnitudes,
                           1,
                           vDSP_Length(inputCount))
                
                vDSP_destroy_fftsetup(fftSetup)
                return scaledMagnitudes
            }
        }
    }
    
    static func estimateFrequency(FftBuffer: [Float], frameCount: Int, sampleRate: Double) -> Float {
        guard FftBuffer.count > 0, let maxIndex = FftBuffer.maxIndex, maxIndex > 0 else {
            return 0.0
        }
        
        let y2 = abs(FftBuffer[maxIndex])
        let y1 = maxIndex == 0 ? y2 : abs(FftBuffer[maxIndex - 1])
        let y3 = maxIndex == FftBuffer.count - 1 ? y2 : abs(FftBuffer[maxIndex + 1])
        let location: Int
        
        if y1 > y3 {
          let a = y2 / y1
          let d = a / (1 + a)
          location = maxIndex - 1 + Int(round(d))
        } else {
          let a = y3 / y2
          let d = a / (1 + a)
          location = maxIndex + Int(round(d))
        }

        let sanitizedLocation = sanitize(location: location, reserveLocation: maxIndex, elements: FftBuffer)
        
        return Float(sanitizedLocation) * Float(sampleRate) / (Float(frameCount) * 2)
    }
    
    static func sanitize(location: Int, reserveLocation: Int, elements: [Float]) -> Int {
        return location >= 0 && location < elements.count
            ? location
            : reserveLocation
    }

    static func interpolatedVectorFrom(magnitudes: [Float], indices: [Float], count: Int) -> [Float] {
        assert(magnitudes.count == indices.count,
               "`magnitudes.count` must equal `indices.count`.")

        var c = [Float](repeating: 0, count: count)

        let stride = vDSP_Stride(1)

        vDSP_vgenp(magnitudes, stride,
                   indices, stride,
                   &c, stride,
                   vDSP_Length(count),
                   vDSP_Length(magnitudes.count))

        return c
    }


//    // Multiplies the frequency-domain representation of `input` by
//    // `dctMultiplier`, and returns the temporal-domain representation
//    // of the product.
//    func apply(dctMultiplier: [Float], toInput input: [Float]) -> [Float] {
//        // Perform forward DCT.
//        forwardDCT?.transform(input,
//                              result: &forwardDCT_PreProcessed)
//        // Multiply frequency-domain data by `dctMultiplier`.
//        vDSP.multiply(dctMultiplier,
//                      forwardDCT_PreProcessed,
//                      result: &forwardDCT_PostProcessed)
//
//        // Perform inverse DCT.
//        inverseDCT?.transform(forwardDCT_PostProcessed,
//                              result: &inverseDCT_Result)
//
//        // In-place scale inverse DCT result by n / 2.
//        // Output samples are now in range -1...+1
//        vDSP.divide(inverseDCT_Result,
//                    Float(sampleCount / 2),
//                    result: &inverseDCT_Result)
//
//        return inverseDCT_Result
//    }




}

extension ViewController: UIPickerViewDataSource {
    
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }
    
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return podcasts.count
    }
    
}

extension ViewController: UIPickerViewDelegate {
    
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return Array(podcasts.keys)[row]
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        stop()
        playItem(at: Array(podcasts.values)[row])
    }

}

extension Array where Element: Comparable {

    var maxIndex: Int? {
        return self.enumerated().max(by: {$1.element > $0.element})?.offset
    }

}
