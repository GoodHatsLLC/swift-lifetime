import Foundation

struct LaunchContext: Sendable {
  let launchID: String
  let startedAt: Date
}

enum FakeAuthError: LocalizedError, Sendable {
  case missingUsername
  case invalidCode
  case emptyMessage

  var errorDescription: String? {
    switch self {
    case .missingUsername:
      return "Enter a username before authenticating."
    case .invalidCode:
      return "The fake 2FA code is 4242."
    case .emptyMessage:
      return "Write something before posting."
    }
  }
}

struct AuthSession: Sendable, Hashable {
  let userID: String
  let displayName: String
  let token: String
  let issuedAt: Date
  let expiresAt: Date
}

struct Post: Hashable, Identifiable, Sendable {
  let id: String
  let text: String
  let createdAt: Date
  let userID: String
}
