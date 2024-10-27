//
//  HLSM3UPlaylistParser.swift
//  HLSPlayer
//
//  Created by Davlat Mirmanov on 11.10.2024.
//

import Foundation

final class HLSM3UPlaylistParser {
    
    func parse(data: Data) -> HLSPlaylist? {
        
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        return parse(string: string)
    }
    
    func parse(string playlistContent: String) -> HLSPlaylist? {
        
        guard playlistContent.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U") else {
            return nil
        }
        
        var segments = [HLSMediaSegment]()
        var variantStreams = [HLSVariantStream]()
        var targetDuration: Int? = nil
        var isEndList = false
        
        let playlistLines = playlistContent.components(separatedBy: .newlines)
        var currentDuration: Double? = nil
        var currentTitle: String? = nil
        var isMasterPlaylist = false
        
        var currentBandwidth: Int? = nil
        var currentResolution: String? = nil
        var currentCodecs: String? = nil
        var currentByteRange: HLSByteRange? = nil
        var currentMap: HLSMediaPlaylist.Map? = nil
        
        for line in playlistLines {
            
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine.hasPrefix("#EXTM3U") {
                
                continue
            } else if trimmedLine.hasPrefix("#EXTINF") {
                
                if let extinfRange = trimmedLine.range(of: "#EXTINF:") {
                    let infContent = trimmedLine[extinfRange.upperBound...]
                    let parts = infContent.split(separator: ",", maxSplits: 1).map { String($0) }
                    if let duration = Double(parts[0]) {
                        
                        currentDuration = duration
                    }
                    currentTitle = parts.count > 1 ? parts[1] : nil
                }
            } else if trimmedLine.hasPrefix("#EXT-X-TARGETDURATION") {
                
                if let targetDurationRange = trimmedLine.range(of: "#EXT-X-TARGETDURATION:") {
                    
                    let targetDurationValue = trimmedLine[targetDurationRange.upperBound...]
                    targetDuration = Int(targetDurationValue)
                }
            } else if trimmedLine.hasPrefix("#EXT-X-BYTERANGE") {
                
                let byteRangeContent = trimmedLine.replacingOccurrences(of: "#EXT-X-BYTERANGE:", with: "")
                let byteRangeParts = byteRangeContent.split(separator: "@").map { String($0) }
                
                if let length = Int(byteRangeParts[0]) {
                    
                    let offset = byteRangeParts.count > 1 ? Int(byteRangeParts[1]) : nil
                    currentByteRange = .init(length: length, offset: offset)
                }
            } else if trimmedLine.hasPrefix("#EXT-X-MAP") {
                
                let mapAttributes = trimmedLine.replacingOccurrences(of: "#EXT-X-MAP:", with: "")
                var mapUrl: String? = nil
                var mapByteRange: HLSByteRange? = nil
                
                let components = mapAttributes.split(separator: ",").map { String($0) }
                for component in components {
                    
                    if component.contains("URI=") {
                        
                        mapUrl = component.replacingOccurrences(of: "URI=", with: "").trimmingCharacters(in: .init(charactersIn: "\""))
                    } else if component.contains("BYTERANGE=") {
                        
                        let byteRangeContent = component.replacingOccurrences(of: "BYTERANGE=", with: "").trimmingCharacters(in: .init(charactersIn: "\""))
                        let byteRangeParts = byteRangeContent.split(separator: "@").map { String($0) }
                        if let length = Int(byteRangeParts[0]) {
                            let offset = byteRangeParts.count > 1 ? Int(byteRangeParts[1]) : nil
                            mapByteRange = HLSByteRange(length: length, offset: offset)
                        }
                    }
                }
                
                if let mapUrl = mapUrl {
                    
                    currentMap = HLSMediaPlaylist.Map(url: mapUrl, byteRange: mapByteRange)
                }
            } else if trimmedLine.hasPrefix("#EXT-X-ENDLIST") {
                
                isEndList = true
            } else if trimmedLine.hasPrefix("#EXT-X-STREAM-INF") {
                
                isMasterPlaylist = true
                currentBandwidth = nil
                currentResolution = nil
                currentCodecs = nil
                
                let attributes = trimmedLine.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: "")
                let components = attributes.split(separator: ",").map { String($0) }
                for component in components {
                    if component.contains("BANDWIDTH=") {
                        currentBandwidth = Int(component.replacingOccurrences(of: "BANDWIDTH=", with: ""))
                    } else if component.contains("RESOLUTION=") {
                        currentResolution = component.replacingOccurrences(of: "RESOLUTION=", with: "")
                    } else if component.contains("CODECS=") {
                        currentCodecs = component.replacingOccurrences(of: "CODECS=", with: "").replacingOccurrences(of: "\"", with: "")
                    }
                }
            } else if !trimmedLine.hasPrefix("#") && !trimmedLine.isEmpty {
                
                if isMasterPlaylist {
                    
                    if let bandwidth = currentBandwidth {
                        
                        variantStreams.append(HLSVariantStream(bandwidth: bandwidth,
                                                            resolution: currentResolution,
                                                            codecs: currentCodecs,
                                                            url: trimmedLine))
                        currentBandwidth = nil
                        currentResolution = nil
                        currentCodecs = nil
                    }
                } else {
                    
                    if let duration = currentDuration {
                        
                        let segment = HLSMediaSegment(duration: duration,
                                                      title: currentTitle,
                                                      url: trimmedLine,
                                                      byteRange: currentByteRange)
                        segments.append(segment)
                        currentDuration = nil
                        currentTitle = nil
                        currentByteRange = nil
                    }
                }
            }
        }
        
        if isMasterPlaylist {
            
            return .master(HLSMasterPlaylist(variantStreams: variantStreams))
        } else if let targetDuration {
            
            return .media(HLSMediaPlaylist(targetDuration: targetDuration,
                                           segments: segments,
                                           isEndList: isEndList,
                                           map: currentMap))
        } else {
            
            return nil
        }
    }
}

