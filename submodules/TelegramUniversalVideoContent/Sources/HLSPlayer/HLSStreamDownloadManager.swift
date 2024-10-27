//
//  HLSStreamDownloadManager.swift
//  HLSPlayer
//
//  Created by Davlat Mirmanov on 13.10.2024.
//

import Foundation
import CoreMedia

final class HLSStreamDownloadManager {
    
    private(set) var source: HLSStreamSource?
    var didDownloadSegment: ((_ url: URL, _ startTime: Double, _ bandwidth: Int?) -> Void)?
    var didFailLoadingSegment: ((Error) -> Void)?
    var longestDownloadedTime: Double? {
        source?.totalDurationUntil(segmentIndex: currentSegmentIndex)
    }
    
    private let urlSession = URLSession(configuration: URLSessionConfiguration.ephemeral)
    private var currentSegmentIndex = 0
    private var currentSegmentTask: URLSessionDataTask?
    private var cacheDirectoryURL: URL?
    private let downloadError = NSError(
        domain: "HLSStreamDownloadManager",
        code: 1,
        userInfo: [NSLocalizedFailureErrorKey : "Could not download stream segment."]
    )
    private let segmentURLError = NSError(
        domain: "HLSStreamDownloadManager",
        code: 2,
        userInfo: [NSLocalizedFailureErrorKey : "Segment has bad URL."]
    )
    private let cacheError = NSError(
        domain: "HLSStreamDownloadManager",
        code: 3,
        userInfo: [NSLocalizedFailureErrorKey : "Could not write a segment to disk."]
    )
    private var initData: Data?
    private var currentInitDataTask: URLSessionDataTask?
    
    deinit {
        
        cancelCurrentDownload()
        deleteCacheDirectory()
    }
    
    func set(source: HLSStreamSource?) {
        
        guard self.source != source else { return }
        cancelCurrentDownload()
        self.source = source
        self.initData = nil
        cacheDirectoryURL = createCacheDirectoryURL()
    }
    
    func resume() {
        
        loadCurrentSegment()
    }
    
    func cancelCurrentDownload() {
        
        currentSegmentTask?.cancel()
        currentSegmentTask = nil
        currentInitDataTask?.cancel()
        currentInitDataTask = nil
    }
    
    func loadStarting(time: Double) {
        
        guard
            let source,
            let index = source.segmentIndexFor(time: time),
            index < source.playlist.segments.count
        else { return }
        
        currentSegmentIndex = index
        loadCurrentSegment()
    }
}

private extension HLSStreamDownloadManager {
    
    func loadCurrentSegment() {
        
        guard
            let source,
            let cacheDirectoryURL,
            0 <= currentSegmentIndex,
            currentSegmentIndex < source.playlist.segments.count
        else { return }
        
        guard source.playlist.map == nil || initData != nil else {
            loadInitData()
            return
        }
        
        let startTime = longestDownloadedTime ?? 0
        let segment = source.playlist.segments[currentSegmentIndex]
        let ext = segment.url.components(separatedBy: ".").last ?? "ts"
        let segmentCacheURL = cacheDirectoryURL.appendingPathComponent(segment.urlHash + "." + ext, isDirectory: false)
        if FileManager.default.fileExists(atPath: segmentCacheURL.path) {
            
            self.currentSegmentIndex += 1
            self.didDownloadSegment?(segmentCacheURL, startTime, nil)
            return
        }
        
        let downloadURL: URL
        if segment.url.hasPrefix("http") {
            
            if let url = URL(string: segment.url) {
                downloadURL = url
            }
            else {
                didFailLoadingSegment?(segmentURLError)
                return
            }
        }
        else {
            downloadURL = source.baseURL.appendingPathComponent(segment.url, isDirectory: false)
        }
        
        guard !(currentSegmentTask?.originalRequest?.url == downloadURL && currentSegmentTask?.state == .running) else { return }
        currentSegmentTask?.cancel()
        
        let bandwidthMeasurer = HLSNetworkBandwidthMeasurer()
        bandwidthMeasurer.startMeasurement()

        var request = URLRequest(url: downloadURL)
        if let byteRange = segment.byteRange {
            let offset = (byteRange.offset ?? source.byteOffsetFor(segmentIndex: currentSegmentIndex) ?? 0)
            request.setValue("bytes=\(offset)-\(offset + byteRange.length - 1)", forHTTPHeaderField: "Range")
        }
        
        currentSegmentTask = urlSession.dataTask(with: request) { [weak self] data, _, error in
            
            guard let self else { return }

            if var data {
                
                if let initData = self.initData {
                    
                    data = initData + data
                }
                do {
                    
                    try data.write(to: segmentCacheURL)
                    self.currentSegmentIndex += 1
                    let bandwidth = bandwidthMeasurer.finishMeasurement(downloadedByteCount: data.count)
                    self.didDownloadSegment?(segmentCacheURL, startTime, bandwidth)
                } catch {
                    
                    didFailLoadingSegment?(cacheError)
                }
            }
            else if let error {
                if (error as NSError).code != NSURLErrorCancelled {
                    self.didFailLoadingSegment?(error)
                }
            }
            else {
                self.didFailLoadingSegment?(downloadError)
            }
        }
            
        currentSegmentTask?.resume()
    }
    
    func loadInitData() {
        
        guard let source, let map = source.playlist.map else { return }
        let downloadURL: URL
        if map.url.hasPrefix("http") == true {
            
            if let url = URL(string: map.url) {
                downloadURL = url
            }
            else {
                didFailLoadingSegment?(segmentURLError)
                return
            }
        }
        else {
            downloadURL = source.baseURL.appendingPathComponent(map.url, isDirectory: false)
        }
        guard !(currentInitDataTask?.originalRequest?.url == downloadURL && currentInitDataTask?.state == .running) else { return }
        currentInitDataTask?.cancel()
        var request = URLRequest(url: downloadURL)
        if let byteRange = map.byteRange {
            
            let offset = byteRange.offset ?? 0
            request.setValue("bytes=\(offset)-\(offset + byteRange.length - 1)", forHTTPHeaderField: "Range")
        }
        
        currentInitDataTask = urlSession.dataTask(with: request) { [weak self] data, _, error in
            
            guard let self else { return }
            if let data {
                
                self.initData = data
                self.loadCurrentSegment()
            }
            else if let error {
                
                if (error as NSError).code != NSURLErrorCancelled {
                    
                    self.didFailLoadingSegment?(error)
                }
            }
            else {
                
                self.didFailLoadingSegment?(downloadError)
            }
        }
            
        currentInitDataTask?.resume()
    }
    
    func createCacheDirectoryURL() -> URL {
        
        let directoryName = UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
    
    func deleteCacheDirectory() {
        
        guard let cacheDirectoryURL else { return }
        try? FileManager.default.removeItem(at: cacheDirectoryURL)
    }
}
