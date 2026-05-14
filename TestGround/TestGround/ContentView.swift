//
//  ContentView.swift
//  TestGround
//
//  Created by Arthur Schiller on 14.05.26.
//

import SwiftUI
import FirebaseCore
import FirebaseFirestore

struct ContentView: View {
    @State private var instantiationStatus: String = "tap to instantiate"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("FirebaseFirestore smoke test")
                .font(.headline)
            Text(instantiationStatus)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.center)
            Button("Instantiate Firestore") {
                instantiationStatus = instantiate()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear {
            instantiationStatus = instantiate()
        }
    }

    private func instantiate() -> String {
        if FirebaseApp.app() == nil {
            let opts = FirebaseOptions(
                googleAppID: "1:000000000000:ios:0000000000000000",
                gcmSenderID: "000000000000"
            )
            opts.projectID = "smoke-test"
            opts.apiKey = "AIza-smoke-test"
            FirebaseApp.configure(options: opts)
        }
        let firestore = Firestore.firestore()
        return "OK: \(type(of: firestore))"
    }
}

#Preview {
    ContentView()
}
