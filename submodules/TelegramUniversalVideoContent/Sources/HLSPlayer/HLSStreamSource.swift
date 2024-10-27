//
//  HLSStreamSource.swift
//  HLSPlayer
//
//  Created by Davlat Mirmanov on 19.10.2024.
//

import Foundation

struct HLSStreamSource: Equatable {
    
    let playlist: HLSMediaPlaylist
    let baseURL: URL
    let bandwidth: Int?
    let resolution: String?
    let codecs: String?
    var resolutionSize: CGSize? {
        
        guard let resolution else { return nil }
        let sides = resolution.split(separator: "x")
        guard sides.count == 2, let width = Int(sides[0]), let height = Int(sides[1]) else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
    var totalDuration: Double {
        
        playlist.segments.reduce(0, { $0 + $1.duration })
    }
    
    init(
        playlist: HLSMediaPlaylist,
        baseURL: URL,
        bandwidth: Int? = nil,
        resolution: String? = nil,
        codecs: String? = nil
    ) {
        
        self.playlist = playlist
        self.baseURL = baseURL
        self.bandwidth = bandwidth
        self.resolution = resolution
        self.codecs = codecs
    }
    
    func segmentIndexFor(time: Double) -> Int? {
        
        var totalTime: Double = 0
        for (index, segment) in playlist.segments.enumerated() {
            
            if totalTime + segment.duration >= time {
                
                return index
            }
            totalTime += segment.duration
        }
        return nil
    }
    
    func totalDurationUntil(segmentIndex: Int) -> Double? {
        
        guard 0 < segmentIndex else { return 0 }
        guard segmentIndex <= playlist.segments.count else { return nil }
        return playlist.segments[0..<segmentIndex].reduce(0, { $0 + $1.duration })
    }
    
    func byteOffsetFor(segmentIndex: Int) -> Int? {
        
        guard 0 < segmentIndex else { return 0 }
        guard segmentIndex <= playlist.segments.count else { return nil }
        var mapOffset = 0
        if let byteRange = playlist.map?.byteRange {
            
            mapOffset += (byteRange.offset ?? 0) + byteRange.length
        }
        return playlist.segments[0..<segmentIndex].reduce(mapOffset, { $0 + ($1.byteRange?.length ?? 0) })
    }
}
