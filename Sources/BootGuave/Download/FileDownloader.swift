import Foundation

/// Download grande (ISO/IPSW) com progresso e cancelamento. Só move para o destino
/// quando termina, então um download interrompido nunca vira um arquivo "pronto" pela metade.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private let lock = NSLock()

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            lock.withLock { self.task = task }
            task.resume()
        }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(DownloadError.httpStatus(http.statusCode)))
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            finish(.failure(cancelled ? DownloadError.cancelled : error))
        }
        session.finishTasksAndInvalidate()
    }
}

enum DownloadError: LocalizedError {
    case httpStatus(Int)
    case cancelled
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return String(localized: "O servidor respondeu com erro HTTP \(code).")
        case .cancelled: return String(localized: "Download cancelado.")
        case .notFound(let what): return String(localized: "Não encontrei a versão mais recente de \(what) no servidor oficial.")
        }
    }
}
