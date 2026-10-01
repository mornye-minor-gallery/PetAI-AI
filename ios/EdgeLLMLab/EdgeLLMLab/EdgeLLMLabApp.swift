//
//  EdgeLLMLabApp.swift
//  EdgeLLMLab
//
//  Created by 김김민석 on 7/24/26.
//

import SwiftUI

@main
struct EdgeLLMLabApp: App {
    var body: some Scene {
        WindowGroup {
            #if RESOURCE_BENCH
            ResourceBenchView()
            #else
            ContentView()
            #endif
        }
    }
}
