//
//  HLSPlaylistResolver.swift
//  HLSPlayer
//
//  Created by Davlat Mirmanov on 19.10.2024.
//

import Foundation

final class HLSPlaylistResolver {
    
    private let urlSession = URLSession(configuration: URLSessionConfiguration.ephemeral)
    private let playlistParser = HLSM3UPlaylistParser()
    private var completion: ((Result<([HLSStreamSource], Int), Error>) -> Void)?
    private let downloadError = NSError(
        domain: "HLSPlaylistResolver",
        code: 1,
        userInfo: [NSLocalizedFailureErrorKey : "Could not download playlist."]
    )
    private let parseError = NSError(
        domain: "HLSPlaylistResolver",
        code: 2,
        userInfo: [NSLocalizedFailureErrorKey : "Could not parse playlist."]
    )
    private let masterPlaylistResolveError = NSError(
        domain: "HLSPlaylistResolver",
        code: 3,
        userInfo: [NSLocalizedFailureErrorKey : "Could not resolve master playlist. It was no variant streams or they all failed to load."]
    )
    private var bandwidthMeasurements = [Int]()
    private var averageBandwidth: Int { bandwidthMeasurements.reduce(0, +) / bandwidthMeasurements.count }
    
    func getStreamSources(url: URL, completion: @escaping (Result<([HLSStreamSource], Int), Error>) -> Void) {
        
        self.completion = completion
        bandwidthMeasurements = []
        downloadPlaylist(url: url)
    }
}

private extension HLSPlaylistResolver {
    
    func downloadPlaylist(url: URL) {
        
        let bandwidthMeasurer = HLSNetworkBandwidthMeasurer()
        bandwidthMeasurer.startMeasurement()
        urlSession.dataTask(with: URLRequest(url: url)) { [weak self] data, response, error in
            
            guard let self else { return }
            guard let data, error == nil else {
                self.completion?(.failure(error ?? self.downloadError))
                return
            }
            self.bandwidthMeasurements.append(bandwidthMeasurer.finishMeasurement(downloadedByteCount: data.count))
            guard let playlist = self.playlistParser.parse(data: data) else {
                
                self.completion?(.failure(error ?? self.parseError))
                return
            }
            didDownload(playlist: playlist, baseURL: url.deletingLastPathComponent())
        }.resume()
    }
    
    func didDownload(playlist: HLSPlaylist, baseURL: URL) {
        
        switch playlist {
        
        case .media(let mediaPlaylist):
            let source = HLSStreamSource(playlist: mediaPlaylist, baseURL: baseURL)
            completion?(.success(([source], averageBandwidth)))
        
        case .master(let masterPlaylist):
            downloadVariantsOf(playlist: masterPlaylist, baseURL: baseURL)
        }
    }
    
    func downloadVariantsOf(playlist: HLSMasterPlaylist, baseURL: URL) {
        
        var sources = [HLSStreamSource]()
        var totalByteCount = 0
        let bandwidthMeasurer = HLSNetworkBandwidthMeasurer()
        bandwidthMeasurer.startMeasurement()
        let dispatchGroup = DispatchGroup()
        playlist.variantStreams.forEach { variant in
            
            let downloadURL: URL
            if variant.url.hasPrefix("http") {
                if let url = URL(string: variant.url) {
                    downloadURL = url
                }
                else {
                    return
                }
            }
            else {
                downloadURL = baseURL.appendingPathComponent(variant.url, isDirectory: false)
            }
            
            dispatchGroup.enter()
            urlSession.dataTask(with: URLRequest(url: downloadURL)) { [weak self] data, response, error in
                
                guard let self, let data, error == nil else {
                    
                    dispatchGroup.leave()
                    return
                }
                
                if let playlist = self.playlistParser.parse(data: data),
                    case let .media(mediaPlaylist) = playlist
                {
                    
                    let source = HLSStreamSource(
                        playlist: mediaPlaylist,
                        baseURL: downloadURL.deletingLastPathComponent(),
                        bandwidth: variant.bandwidth,
                        resolution: variant.resolution,
                        codecs: variant.codecs
                    )
                    sources.append(source)
                    totalByteCount += data.count
                }
                dispatchGroup.leave()
            }
            .resume()
        }
        
        dispatchGroup.notify(queue: .main) { [weak self] in
            
            guard let self else { return }
            guard !sources.isEmpty else {
                
                self.completion?(.failure(self.masterPlaylistResolveError))
                return
            }
            bandwidthMeasurements.append(bandwidthMeasurer.finishMeasurement(downloadedByteCount: totalByteCount))
            self.completion?(.success((sources, averageBandwidth)))
        }
    }
}
