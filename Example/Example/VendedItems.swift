import Foundation

// MARK: - Network Client

actor NetworkClient {
  init(launch: LaunchContext) {
    self.launch = launch
  }

  let launch: LaunchContext

  func login(user: String, twoFactorCode: String) async throws -> AuthSession {
    try await Task.sleep(for: .milliseconds(650))

    let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedUser.isEmpty else {
      throw FakeAuthError.missingUsername
    }
    guard twoFactorCode == "4242" else {
      throw FakeAuthError.invalidCode
    }

    return AuthSession(
      userID: trimmedUser.lowercased(),
      displayName: trimmedUser.capitalized,
      token: "tok_\(UUID().uuidString.prefix(8))",
      issuedAt: .now,
      expiresAt: .now.addingTimeInterval(60 * 45)
    )
  }
}


// MARK: - AuthenticatedNetworkClient

actor AuthenticatedNetworkClient {
  init(session: AuthSession) {
    self.session = session
    self.posts = [
      Post(
        id: "launch-\(session.userID)",
        text: "Signed in from fake launch token \(session.token.prefix(6)).",
        createdAt: session.issuedAt,
        userID: session.userID
      ),
      Post(
        id: "welcome-\(session.userID)",
        text: "Welcome back, \(session.displayName). Press refresh or post an update.",
        createdAt: session.issuedAt.addingTimeInterval(30),
        userID: session.userID
      ),
    ]
  }

  let session: AuthSession
  private var posts: [Post]

  func post(message: String) async throws -> [Post] {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw FakeAuthError.emptyMessage
    }

    try await Task.sleep(for: .milliseconds(220))
    posts.insert(
      Post(
        id: UUID().uuidString,
        text: trimmed,
        createdAt: .now,
        userID: session.userID
      ),
      at: 0
    )
    return posts
  }

  func listPosts() async throws -> [Post] {
    try await Task.sleep(for: .milliseconds(180))
    return posts.sorted { $0.createdAt > $1.createdAt }
  }
}
