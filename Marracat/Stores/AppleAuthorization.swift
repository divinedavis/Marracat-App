import AuthenticationServices
import SwiftUI

struct AppleChallenge: Decodable { let challenge: String; let nonce: String }
struct AppleTokenBody: Encodable {
    let challenge: String
    let idToken: String
    let authorizationCode: String
    let name: String?
}

/// Uses Apple's own button while fetching a one-use server challenge before presenting authorization.
struct AppleAccountButton: UIViewRepresentable {
    var action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: .white)
        // A capsule, like the Google button beside it and the app's pills.
        button.cornerRadius = AccountButtonMetrics.height / 2
        button.addTarget(context.coordinator, action: #selector(Coordinator.signIn), for: .touchUpInside)
        return button
    }
    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) { context.coordinator.action = action; uiView.isEnabled = context.environment.isEnabled }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func signIn() { action() }
    }
}

@MainActor
final class AppleAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleTokenBody, Error>?
    private var controller: ASAuthorizationController?
    private let challenge: AppleChallenge
    private let window: UIWindow
    init(challenge: AppleChallenge, window: UIWindow) { self.challenge = challenge; self.window = window }
    func signIn() async throws -> AppleTokenBody {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = challenge.nonce
            request.state = challenge.challenge
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              credential.state == challenge.challenge,
              let identity = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
              let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) else {
            finish(.failure(ASAuthorizationError(.invalidResponse))); return
        }
        let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
        finish(.success(AppleTokenBody(challenge: challenge.challenge, idToken: identity, authorizationCode: code, name: name)))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<AppleTokenBody, Error>) {
        let pending = continuation; continuation = nil; controller = nil
        pending?.resume(with: result)
    }
}
