//
//  HLSPlayer.swift
//  HLSPlayer
//
//  Created by Davlat Mirmanov on 13.10.2024.
//

import UIKit
import AVFoundation
import SwiftSignalKit

class HLSPlayer {
    
    // Item
    private(set) var currentItem: HLSPlayerItem?
    
    // Playback
    var defaultRate: Double = 1
    var rate: Double = 0 {
        didSet {
            CMTimebaseSetRate(videoLayer.controlTimebase!, rate: rate)
            synchronizer.rate = Float(rate)
            rateDidChange.putNext(rate)
        }
    }
    var rateDidChange = ValuePipe<Double>()
    
    // Timing
    var currentTime: Double {
        currentItem?.currentTime ?? 0
    }
    
    // Config
    var pauseAtItemEnd: Bool = true

    // Audio
    var volume: Double {
        get {
            Double(audioRenderer.volume)
        }
        set {
            audioRenderer.volume = Float(newValue)
        }
    }
    
    // Presentation
    let videoLayer = AVSampleBufferDisplayLayer()
    let audioRenderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    
    private let feedBufferQueue: OperationQueue = {
        
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private lazy var currentTimeUpdater: DisplayLinkUpdater = {
        
        let currentTimeUpdater = DisplayLinkUpdater { [weak self] in
            self?.updateCurrentTime()
        }
        return currentTimeUpdater
    }()
    private var isWaitingToPlay: Bool = false
    private let disposableSet = DisposableSet()
        
    init(playerItem: HLSPlayerItem?) {
        currentItem = playerItem
        setup()
    }
    
    deinit {
        
        currentTimeUpdater.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    func replaceCurrentItem(with playerItem: HLSPlayerItem?) {
        
        currentItem = playerItem
        didChangePlayerItem()
    }
    
    func play() {
        
        guard case .ready = currentItem?.status else {
            
            currentItem?.prepare(completion: { [weak self] status in
                
                guard case .ready = status, let self else { return }
                
                schedulePlay()
                self.currentItem?.seek(to: 0)
            })
            
            return
        }
        
        schedulePlay()
    }
    
    func pause() {
        
        rate = 0
        currentTimeUpdater.isPaused = true
        isWaitingToPlay = false
    }
    
    func seek(to time: Double) {
        
        videoLayer.flush()
        audioRenderer.flush()
        feedBufferQueue.cancelAllOperations()
        CMTimebaseSetTime(
            videoLayer.controlTimebase!,
            time: CMTime(seconds: time, preferredTimescale: 30)
        );
        currentItem?.seek(to: time)
    }
}

private extension HLSPlayer {
    
    func setup() {
        
        videoLayer.videoGravity = .resizeAspect
        if #available(iOS 13.0, *) {
            
            videoLayer.preventsDisplaySleepDuringVideoPlayback = true
        }
        
        var timebase: CMTimebase!
        var clock: CMClock!
        CMAudioClockCreate(allocator: nil, clockOut: &clock)
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: clock, timebaseOut: &timebase)
        CMTimebaseSetRate(timebase, rate: 0.0)
        videoLayer.controlTimebase = timebase
        
        synchronizer.addRenderer(audioRenderer)
        if #available(iOS 14.5, *) {
            
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = true
        }
        
        didChangePlayerItem()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnderBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }
    
    func didChangePlayerItem() {
        
        if let currentItem {
            
            currentItem.didLoadSegment = { [weak self] assetReader in
                
                guard let self else { return }
                let feedBufferOp = FeedBufferOperation(
                    assetReader: assetReader,
                    videoLayer: videoLayer,
                    audioRenderer: audioRenderer
                )
                
                self.feedBufferQueue.addOperation(feedBufferOp)
                
                if self.isWaitingToPlay || self.currentItem?.startsOnFirstEligibleVariant == true {
                    
                    schedulePlay()
                }
            }
            
            disposableSet.add(currentItem.playbackBufferBecameEmpty.signal().start(next: { [weak self] in
                
                guard let self, self.rate > 0 else { return }
                self.rate = 0
                isWaitingToPlay = true
            }))
            
            disposableSet.add(currentItem.didPlayToEndTime.signal().start(next: { [weak self] in
                
                guard self?.pauseAtItemEnd == true else { return }
                self?.pause()
            }))
        }
    }
    
    func updateCurrentTime() {
        
        guard let timebase = videoLayer.controlTimebase else { return }
        let time = CMTimebaseGetTime(timebase).seconds
        
        if videoLayer.status == .failed {
            
            videoLayer.flushAndRemoveImage()
        }
        
        if audioRenderer.status == .failed {
            
            audioRenderer.flush()
        }
        
        currentItem?.seek(to: time)
    }
    
    func schedulePlay() {
        
        guard let currentItem, (currentItem.duration == nil || currentTime < currentItem.duration!) else {
            
            return
        }
        
        guard currentItem.isPlaybackBufferEmpty == false else {
            
            isWaitingToPlay = true
            currentItem.seek(to: currentTime)
            return
        }
        
        rate = defaultRate
        currentTimeUpdater.isPaused = false
        isWaitingToPlay = false
    }
    
    @objc func appDidEnderBackground() {
        
        guard rate > 0 else { return }
        pause()
        isWaitingToPlay = true
    }
    
    @objc func appWillEnterForeground() {
        
        guard isWaitingToPlay else { return }
        schedulePlay()
    }
}

private final class FeedBufferOperation: HLSAsyncOperation, @unchecked Sendable {
    
    var assetReader: AVAssetReader
    var videoLayer: AVSampleBufferDisplayLayer
    var audioRenderer: AVSampleBufferAudioRenderer
    private var didFinishVideo = false
    private var didFinishAudio = false
    
    init(
        assetReader: AVAssetReader,
        videoLayer: AVSampleBufferDisplayLayer,
        audioRenderer: AVSampleBufferAudioRenderer
    ) {
        
        self.assetReader = assetReader
        self.videoLayer = videoLayer
        self.audioRenderer = audioRenderer
        
        super.init()
    }
    
    override func main() {
        
        assetReader.startReading()
        
        let videoOutput = assetReader.outputs.first(where: { $0.mediaType == .video }) as? AVAssetReaderTrackOutput
        let audioOutput = assetReader.outputs.first(where: { $0.mediaType == .audio }) as? AVAssetReaderTrackOutput
        
        guard videoOutput != nil || audioOutput != nil else {
            
            finish()
            return
        }

        videoLayer.requestMediaDataWhenReady(on: DispatchQueue.main) { [weak self, weak videoOutput] in
            
            while self?.videoLayer.isReadyForMoreMediaData == true {
                
                guard
                    self?.isCancelled == false,
                    self?.assetReader.status == .reading,
                    let sampleBuffer = videoOutput?.copyNextSampleBuffer()
                else {
                    
                    self?.videoLayer.stopRequestingMediaData()
                    self?.didFinishVideo = true
                    self?.checkFinish()
                    return
                }
                                
                self?.videoLayer.enqueue(sampleBuffer)
            }
        }
        
        audioRenderer.requestMediaDataWhenReady(on: DispatchQueue.main) { [weak self, weak audioOutput] in
            
            while self?.audioRenderer.isReadyForMoreMediaData == true {
                
                guard
                    self?.isCancelled == false,
                    self?.assetReader.status == .reading,
                    let sampleBuffer = audioOutput?.copyNextSampleBuffer()
                else {
                    
                    self?.audioRenderer.stopRequestingMediaData()
                    self?.didFinishAudio = true
                    self?.checkFinish()
                    return
                }
                                
                self?.audioRenderer.enqueue(sampleBuffer)
            }
        }
    }
    
    private func checkFinish() {
        
        guard didFinishVideo && didFinishAudio else { return }
        finish()
    }
    
}

private final class DisplayLinkUpdater {
    
    var callback: (() -> Void)
    var isPaused: Bool = true {
        didSet {
            displayLink.isPaused = isPaused
        }
    }
    
    var preferredFramesPerSecond: Int = 2 {
        didSet {
            displayLink.preferredFramesPerSecond = preferredFramesPerSecond
        }
    }
    
    private lazy var displayLink: CADisplayLink = {
        
        let displayLink = CADisplayLink(target: self, selector: #selector(update(sender:)))
        displayLink.preferredFramesPerSecond = preferredFramesPerSecond
        displayLink.isPaused = true
        return displayLink
    }()
    
    init(callback: @escaping (() -> Void)) {
        
        self.callback = callback
        displayLink.add(to: .main, forMode: .default)
    }
    
    func invalidate() {
        
        displayLink.invalidate()
    }
    
    @objc private func update(sender: CADisplayLink) {
        
        callback()
    }
}
