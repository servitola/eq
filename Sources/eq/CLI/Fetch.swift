import Foundation

enum HTTPFetch {
    static func checkedData(_ data: Data?, _ response: URLResponse?, _ error: Error?) throws -> Data {
        if let error { throw error }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw URLError(.fileDoesNotExist) }
            if http.statusCode != 200 { throw URLError(.badServerResponse) }
        }
        guard let data else { throw URLError(.zeroByteResource) }
        return data
    }

    static func live(_ url: URL) throws -> Data {
        let request = URLRequest(url: url, timeoutInterval: 20)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(URLError(.unknown))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            result = Result { try checkedData(data, response, error) }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 21) == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
        }
        return try result.get()
    }
}
