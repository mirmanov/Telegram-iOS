//
//  HLSNetworkBandwidthMeasurer.swift
//  HLSPlayer
//
//  Created by Davlat Mirmanov on 26.10.2024.
//

import Foundation

final class HLSNetworkBandwidthMeasurer {
    
    private var startTime: CFAbsoluteTime?
    
    func startMeasurement() {
        
        startTime = CFAbsoluteTimeGetCurrent()
    }
    
    // Returns bits per second
    func finishMeasurement(downloadedByteCount: Int) -> Int {
        
        guard let startTime else { return 0 }
        let endTime = CFAbsoluteTimeGetCurrent()
        let elapsed = endTime - startTime
        return Int((Double(downloadedByteCount) * 8) / elapsed)
    }
}
