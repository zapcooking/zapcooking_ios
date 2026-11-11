import Foundation

// Banners and status lines render `error.localizedDescription`. Without
// LocalizedError a Swift enum error reads "The operation couldn't be
// completed. (wisp.Nip46.NipError error 2.)", so a remote-signer refusal
// showed that instead of the text each case already carries in `description`.

extension Nip46.NipError: LocalizedError {
    nonisolated var errorDescription: String? { description }
}

extension Signer.SignerError: LocalizedError {
    nonisolated var errorDescription: String? { description }
}
