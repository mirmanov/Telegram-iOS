//
//  HLSPlaylist.swift
//  HLSPlayer
//
//  Created by Davlat Mirmanov on 13.10.2024.
//

import Foundation

struct HLSByteRange: Equatable {
    
    let length: Int
    let offset: Int?
}

struct HLSMediaSegment: Equatable {
    
    let duration: Double
    let title: String?
    let url: String
    let byteRange: HLSByteRange?
    
    var urlHash: String {
        
        var hasher = Hasher()
        url.hash(into: &hasher)
        if let byteRange {
            byteRange.length.hash(into: &hasher)
            byteRange.offset.hash(into: &hasher)
        }
        return String(hasher.finalize())
    }
}

struct HLSVariantStream {
    
    let bandwidth: Int
    let resolution: String?
    let codecs: String?
    let url: String
}

struct HLSMediaPlaylist: Equatable {
    
    let targetDuration: Int
    let segments: [HLSMediaSegment]
    let isEndList: Bool
    let map: Map?
    
    struct Map: Equatable {
        
        let url: String
        let byteRange: HLSByteRange?
    }
}

struct HLSMasterPlaylist {
    
    let variantStreams: [HLSVariantStream]
}

enum HLSPlaylist {
    
    case media(HLSMediaPlaylist)
    case master(HLSMasterPlaylist)
}
