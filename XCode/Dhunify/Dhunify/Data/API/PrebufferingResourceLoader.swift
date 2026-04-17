//
//  PrebufferingResourceLoader.swift
//  Dhunify
//
//  AVAssetResourceLoaderDelegate that pre-downloads the first ~768 KB of an
//  MP4/M4A audio stream into RAM *before* AVPlayer is given the URL. AVPlayer
//  then asks us for bytes via a custom scheme; we serve the moov atom and
//  first few fragments from memory (instant) and stream everything else over
//  the network with Range requests.
//
//  Why: AVURLAsset on a cold TCP connection does a waterfall of Range probes
//  to locate the moov atom. Each probe = one RTT. Against a googlevideo or
//  JioSaavn CDN edge from Canada that's ~6-10s. Prebuffering collapses that
//  to one round-trip and reuses the warmed TCP window for subsequent reads.
//
//  Pattern is the same one Apple Music / Spotify use for sub-second starts.
//
//  Usage:
//      let loader = PrebufferingResourceLoader(realURL: url)
//      loader.startPrefetch()
//      let asset = loader.makeAsset()
//      let item  = AVPlayerItem(asset: asset)
//      // retain `loader` for the lifetime of `item`
//
//  One loader per item. Do not reuse across different URLs.
//

import Foundation
import AVFoundation
import os

private let loaderLog = Logger(subsystem: "com.diphoria.Dhunify", category: "PrebufferLoader")

final class PrebufferingResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    static let customScheme = "dhunify-audio"
    private static let prefetchBytes = 768 * 1024

    private let realURL: URL
    private let workQueue = DispatchQueue(label: "dhunify.prebuffer", qos: .userInitiated)
    private let session: URLSession

    // All fields below are accessed only on `workQueue`.
    private var prebuffer: Data?
    private var totalBytes: Int64 = -1
    private var contentType: String = "public.mpeg-4-audio"
    private var prefetchTask: URLSessionDataTask?
    private var prefetchStarted = false
    private var prefetchCompleted = false
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var activeTasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(realURL: URL) {
        self.realURL = realURL
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 60
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    /// Build an AVURLAsset wired to this loader. The asset's URL uses a
    /// fake scheme so AVFoundation routes every byte request through us.
    func makeAsset() -> AVURLAsset {
        var comps = URLComponents(url: realURL, resolvingAgainstBaseURL: false)!
        comps.scheme = Self.customScheme
        let fake = comps.url ?? realURL
        let asset = AVURLAsset(url: fake)
        asset.resourceLoader.setDelegate(self, queue: workQueue)
        return asset
    }

    /// Kick off the prefetch GET. Non-blocking. Safe to call multiple times.
    func startPrefetch() {
        workQueue.async { [weak self] in
            guard let self, !self.prefetchStarted else { return }
            self.prefetchStarted = true

            var req = URLRequest(url: self.realURL)
            req.setValue("bytes=0-\(Self.prefetchBytes - 1)", forHTTPHeaderField: "Range")
            req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

            let task = self.session.dataTask(with: req) { [weak self] data, resp, err in
                guard let self else { return }
                self.workQueue.async {
                    self.prefetchTask = nil
                    self.prefetchCompleted = true

                    if let http = resp as? HTTPURLResponse {
                        if let ct = http.value(forHTTPHeaderField: "Content-Type"),
                           !ct.isEmpty {
                            self.contentType = ct
                        }
                        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
                           let slash = cr.firstIndex(of: "/") {
                            let tail = String(cr[cr.index(after: slash)...])
                            self.totalBytes = Int64(tail) ?? -1
                        } else if http.statusCode == 200,
                                  let cl = http.value(forHTTPHeaderField: "Content-Length"),
                                  let n = Int64(cl) {
                            self.totalBytes = n
                        }
                    }

                    if let data, err == nil, !data.isEmpty {
                        self.prebuffer = data
                        loaderLog.info("prefetched \(data.count)B total=\(self.totalBytes)")
                    } else if let err {
                        loaderLog.warning("prefetch failed: \(err.localizedDescription, privacy: .public)")
                    }

                    let drain = self.pending
                    self.pending.removeAll()
                    for r in drain where !r.isFinished && !r.isCancelled {
                        self.dispatch(r)
                    }
                }
            }
            self.prefetchTask = task
            task.resume()
        }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        // Delegate queue === workQueue, so no async hop needed.
        if !prefetchCompleted && prebuffer == nil {
            pending.append(request)
            return true
        }
        dispatch(request)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel request: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(request)
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        pending.removeAll { $0 === request }
    }

    // MARK: - Dispatch

    private func dispatch(_ request: AVAssetResourceLoadingRequest) {
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.isByteRangeAccessSupported = true
            if totalBytes > 0 {
                info.contentLength = totalBytes
            }
        }

        guard let dr = request.dataRequest else {
            request.finishLoading()
            return
        }

        let requestedOffset = dr.requestedOffset
        let requestedLength = Int64(dr.requestedLength)
        let currentOffset = dr.currentOffset > 0 ? dr.currentOffset : requestedOffset
        let endByte = requestedOffset + requestedLength  // exclusive

        if let pb = prebuffer, currentOffset < Int64(pb.count) {
            let sliceEnd = min(Int64(pb.count), endByte)
            if sliceEnd > currentOffset {
                let sub = pb.subdata(in: Int(currentOffset)..<Int(sliceEnd))
                dr.respond(with: sub)
                if sliceEnd >= endByte {
                    request.finishLoading()
                    return
                }
                fetchRemote(from: sliceEnd, to: endByte, for: request)
                return
            }
        }

        fetchRemote(from: currentOffset, to: endByte, for: request)
    }

    private func fetchRemote(from startByte: Int64,
                             to endByte: Int64,
                             for request: AVAssetResourceLoadingRequest) {
        guard endByte > startByte else {
            request.finishLoading()
            return
        }

        var req = URLRequest(url: realURL)
        req.setValue("bytes=\(startByte)-\(endByte - 1)", forHTTPHeaderField: "Range")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let id = ObjectIdentifier(request)
        let task = session.dataTask(with: req) { [weak self] data, _, err in
            guard let self else { return }
            self.workQueue.async {
                self.activeTasks.removeValue(forKey: id)
                if request.isFinished || request.isCancelled { return }
                if let err {
                    request.finishLoading(with: err)
                    return
                }
                if let data, !data.isEmpty {
                    request.dataRequest?.respond(with: data)
                }
                request.finishLoading()
            }
        }
        activeTasks[id] = task
        task.resume()
    }
}
