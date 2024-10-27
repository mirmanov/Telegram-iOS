//
//  HLSPlayerItem.swift
//  HLSPlayer
//
//  Created by Davlat Mirmanov on 19.10.2024.
//

import Foundation
import AVFoundation
import FFMpegBinding
import SwiftSignalKit

class HLSPlayerItem {
    
    // Status
    private(set) var status = Status.none
    private(set) var sources: [HLSStreamSource]?
    
    // Timing
    private(set) var currentTime: Double = 0
    var duration: Double? { selectedSource?.totalDuration }
    
    // Buffering
    var isPlaybackLikelyToKeepUp: Bool = false {
        didSet {
            if isPlaybackLikelyToKeepUp && !oldValue {
                playbackBecameLikelyToKeepUp.putNext(())
            }
        }
    }
    var isPlaybackBufferFull: Bool = false {
        didSet {
            if isPlaybackBufferFull && !oldValue {
                playbackBufferBecameFull.putNext(())
            }
        }
    }
    var isPlaybackBufferEmpty: Bool = false {
        didSet {
            if isPlaybackBufferEmpty && !oldValue {
                playbackBufferBecameEmpty.putNext(())
            }
        }
    }
    
    // Config
    var startsOnFirstEligibleVariant: Bool = false
    // Setting preferredPeakBitRate to 0 will enable automatic bitrate selection
    var preferredPeakBitRate: Int = 0 {
        didSet {
            selectBestSourceFor(bandwidth: preferredPeakBitRate)
        }
    }
    var bufferDuration: Double = 10 // Seconds to preload
    
    // Events
    let didPlayToEndTime = ValuePipe<Void>()
    let failedToPlayToEndTime = ValuePipe<Error>() // TODO
    var playbackBecameLikelyToKeepUp = ValuePipe<Void>() // TODO
    var playbackBufferBecameFull = ValuePipe<Void>()
    var playbackBufferBecameEmpty = ValuePipe<Void>()
    var presentationSizeDidChange = ValuePipe<CGSize>()
    var didLoadSegment: ((AVAssetReader) -> Void)?
    
    // Presentation
    var presentationSize: CGSize = .zero {
        didSet {
            if presentationSize != oldValue {
                presentationSizeDidChange.putNext(presentationSize)                
            }
        }
    }
        
    // Private
    private let streamDownloadManager: HLSStreamDownloadManager = HLSStreamDownloadManager()
    private let playlistResolver = HLSPlaylistResolver()
    private let playlistURL: URL
    private var selectedSource: HLSStreamSource? {
        didSet {
            streamDownloadManager.set(source: selectedSource)
        }
    }
    private let assetPreparationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var prepareCompletionHandlers = [(Status) -> Void]()
    private let disposableSet = DisposableSet()
    
    init(url: URL) {
        playlistURL = url
        
        setup()
    }
    
    func prepare(completion: @escaping (Status) -> Void) {
        switch status {
        
        case .none, .failed:
            
            status = .loadingPlaylist
            prepareCompletionHandlers.append(completion)
            playlistResolver.getStreamSources(url: playlistURL) { [weak self] result in
                
                guard let self else { return }
                
                switch result {
               
                case .success((let sources, let networkBandwidth)):
                    
                    self.sources = sources
                    self.status = .ready
                    self.isPlaybackBufferEmpty = true
                    
                    let bitRate = self.preferredPeakBitRate != 0 ? self.preferredPeakBitRate : networkBandwidth
                    selectBestSourceFor(bandwidth: bitRate)
                    
                    prepareCompletionHandlers.forEach({ $0(self.status) })
                
                case .failure(let error):
                    
                    self.status = .failed(error)
                    prepareCompletionHandlers.forEach({ $0(self.status) })
                }
            }
        
        case .ready:
            completion(.ready)
        
        case .loadingPlaylist:
            prepareCompletionHandlers.append(completion)
        }
    }
    
    func seek(to time: Double) {
        
        guard case .ready = status else { return }
        guard let longestDownloadedTime = streamDownloadManager.longestDownloadedTime else { return }
                
        if longestDownloadedTime < time || time < currentTime {
            
            isPlaybackBufferEmpty = true
            assetPreparationQueue.cancelAllOperations()
            streamDownloadManager.loadStarting(time: time)
        }
        
        currentTime = time
        
        checkBuffer()
        
        if currentTime >= (duration ?? 0) {
            
            didPlayToEndTime.putNext(())
        }
    }
}

private extension HLSPlayerItem {
    
    func setup() {
        
        streamDownloadManager.didDownloadSegment = { [weak self] url, startTime, networkBandwidth in
            
            self?.isPlaybackBufferEmpty = false
            
            if let self, let networkBandwidth {
                
                let bitRate = self.preferredPeakBitRate != 0 ? self.preferredPeakBitRate : networkBandwidth
                self.selectBestSourceFor(bandwidth: bitRate)
            }
            self?.checkBuffer()
            
            let prepareAssetOp = PrepareAssetOperation(assetURL: url, startTime: startTime) { assetReader in
                
                self?.didLoadSegment?(assetReader)
            }
            self?.assetPreparationQueue.addOperation(prepareAssetOp)
        }
        
    }
    
    func checkBuffer() {
        
        guard let longestDownloadedTime = streamDownloadManager.longestDownloadedTime else { return }
        guard longestDownloadedTime <= currentTime + bufferDuration else {
            
            isPlaybackBufferFull = true
            return
        }
        isPlaybackBufferFull = false
        streamDownloadManager.resume()
    }
    
    func selectBestSourceFor(bandwidth: Int) {

        let sortedSources = sources?
            .sorted(by: { source1, source2 in
                
                guard let bandwidth1 = source1.bandwidth, let bandwidth2 = source2.bandwidth else { return false }
                return bandwidth1 > bandwidth2
            })
        
        let source = sortedSources?
            .first(where: { source in
                
                guard let bw = source.bandwidth else { return false }
                return bw <= bandwidth
            })
        
        selectedSource = source ?? sortedSources?.last
        presentationSize = selectedSource?.resolutionSize ?? .zero
    }
}

extension HLSPlayerItem {
    
    enum Status {
        
        case none
        case loadingPlaylist
        case ready
        case failed(Error)
    }
}

private final class PrepareAssetOperation: HLSAsyncOperation, @unchecked Sendable {
    
    private let assetURL: URL
    private let startTime: Double
    private let completion: (AVAssetReader) -> Void
    
    init(
        assetURL: URL,
        startTime: Double,
        completion: @escaping (AVAssetReader) -> Void
    ) {
        
        self.assetURL = assetURL
        self.startTime = startTime
        self.completion = completion

        super.init()
    }
    
    override func main() {
        
        convertSegment(assetURL) { [weak self] convertedURL in
                
                guard self?.isCancelled == false, let convertedURL else {
                    
                    self?.finish()
                    return
                }
                
                let asset = AVURLAsset(url: convertedURL)
                asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
                    
                    guard self?.isCancelled == false else {
                        self?.finish()
                        return
                    }
                    
                    guard let assetReader = try? AVAssetReader(asset: asset) else {
                        self?.finish()
                        return
                    }

                    var audioOutput: AVAssetReaderTrackOutput?
                    if let audioTrack = asset.tracks(withMediaType: .audio).first {
                        
                        let audioSettings: [String: Any] = [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVSampleRateKey: 44100,
                            AVNumberOfChannelsKey: 2,
                            AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsNonInterleaved: false,
                            AVLinearPCMIsFloatKey: false,
                            AVLinearPCMIsBigEndianKey: false
                        ]

                        audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioSettings)
                        audioOutput?.alwaysCopiesSampleData = false

                        if assetReader.canAdd(audioOutput!) {
                            
                            assetReader.add(audioOutput!)
                        }
                    }
                    
                    var videoOutput: AVAssetReaderTrackOutput?
                    if let videoTrack = asset.tracks(withMediaType: .video).first {
                        
                        let videoSettings: [String: Any] = [
                            (kCVPixelBufferPixelFormatTypeKey as String): kCVPixelFormatType_32BGRA
                        ]

                        videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoSettings)
                        videoOutput?.alwaysCopiesSampleData = false

                        if assetReader.canAdd(videoOutput!) {
                            
                            assetReader.add(videoOutput!)
                        }
                    }
                    
                    guard self?.isCancelled == false, !assetReader.outputs.isEmpty else {
                        
                        self?.finish()
                        return
                    }
                    
                    self?.completion(assetReader)
                    self?.finish()
                }
            }
    }
    
    private func convertSegment(_ inputURL: URL, completion: @escaping (URL?) -> Void) {
        
        let outputURL = inputURL
            .deletingLastPathComponent()
            .appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent + "-converted.mp4", isDirectory: false)
        
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            
            completion(outputURL)
            return
        }
        
        FFMpegRemuxer.repack(inputURL.path, to: outputURL.path, start_time: startTime)
        completion(outputURL)
    }
}
