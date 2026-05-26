//
//  YTStreamResourceLoader.swift
//  Dhunify
//
//  EXPERIMENTAL (flag: PlayerViewModel.resourceLoaderMode).
//
//  Feeds AVPlayer the RAW googlevideo m4a directly — on-device, NO Fly. The
//  phone already resolved a URL valid for its own IP, so there's no remote
//  resolve / download / remux. The catch that historically broke direct play
//  was googlevideo throttling AVPlayer's open-ended range to ~30 KB/s → stuck
//  `.unknown`. Here we intercept every load via AVAssetResourceLoaderDelegate
//  and satisfy it with BOUNDED sub-range requests (the same trick the worker
//  uses, client-side) so the throttle never engages.
//
//  Goal: cold-instant start. Seek works because itag139 carries a `sidx`.
//

import AVFoundation
import UniformTypeIdentifiers

final class YTStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    /// Custom scheme so AVFoundation routes loading through this delegate
    /// instead of fetching the URL itself.
    static let scheme = "ytstream"

    private let realURL: URL
    private let contentLength: Int64
    private let contentTypeUTI: String
    private let chunk: Int64 = 2 * 1024 * 1024  // 2 MB bounded sub-requests
    private let queue = DispatchQueue(label: "dhunify.ytStreamLoader")
    private let session: URLSession

    init(realURL: URL, contentLength: Int64) {
        self.realURL = realURL
        self.contentLength = contentLength
        self.contentTypeUTI = UTType(mimeType: "audio/mp4")?.identifier ?? "public.mpeg-4"
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    /// Build an AVURLAsset whose URL carries the custom scheme → loading is
    /// handled by `loader` (which must be retained for the asset's lifetime).
    static func makeAsset(realURL: URL, contentLength: Int64) -> (AVURLAsset, YTStreamResourceLoader)? {
        guard contentLength > 0,
              var comps = URLComponents(url: realURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = scheme
        guard let customURL = comps.url else { return nil }
        let asset = AVURLAsset(url: customURL)
        let loader = YTStreamResourceLoader(realURL: realURL, contentLength: contentLength)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }

    /// Parse the `clen` query param googlevideo always includes → content length.
    static func contentLength(from url: URL) -> Int64? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let clen = items.first(where: { $0.name == "clen" })?.value,
              let n = Int64(clen), n > 0 else { return nil }
        return n
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentTypeUTI
            info.isByteRangeAccessSupported = true
            info.contentLength = contentLength
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = dataRequest.requestedOffset + Int64(dataRequest.currentOffset - dataRequest.requestedOffset)
        let end: Int64 = dataRequest.requestsAllDataToEndOfResource
            ? contentLength - 1
            : min(dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1, contentLength - 1)
        fetchBounded(loadingRequest, dataRequest, from: max(start, dataRequest.requestedOffset), to: end)
        return true
    }

    private func fetchBounded(_ loadingRequest: AVAssetResourceLoadingRequest,
                              _ dataRequest: AVAssetResourceLoadingDataRequest,
                              from: Int64, to: Int64) {
        if loadingRequest.isCancelled || loadingRequest.isFinished { return }
        if from > to { loadingRequest.finishLoading(); return }
        let subEnd = min(from + chunk - 1, to)
        var req = URLRequest(url: realURL)
        req.setValue("bytes=\(from)-\(subEnd)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }
            self.queue.async {
                if loadingRequest.isCancelled || loadingRequest.isFinished { return }
                if let error = error {
                    loadingRequest.finishLoading(with: error)
                    return
                }
                guard let data = data, !data.isEmpty else {
                    loadingRequest.finishLoading()
                    return
                }
                dataRequest.respond(with: data)
                let next = from + Int64(data.count)
                if next > to {
                    loadingRequest.finishLoading()
                } else {
                    self.fetchBounded(loadingRequest, dataRequest, from: next, to: to)
                }
            }
        }
        task.resume()
    }
}
