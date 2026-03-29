//
//  App.swift
//  player
//
//  Created by nvv on 29/3/26.
//

import SwiftUI

private struct TabBarStyler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        DispatchQueue.main.async {
            let appearance = UITabBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundEffect = nil
            appearance.backgroundColor = .clear
            appearance.shadowColor = UIColor.white.withAlphaComponent(0.08)
            
            UITabBar.appearance().standardAppearance = appearance
            if #available(iOS 15.0, *) {
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }
            UITabBar.appearance().isTranslucent = true
            
            UITabBar.appearance().tintColor = .white
            UITabBar.appearance().unselectedItemTintColor = UIColor.white.withAlphaComponent(0.55)
        }
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct AppView: View {
    @State private var activePlayerURL: URL?
    
    var body: some View {
        ZStack {
            TabView {
                NavigationStack {
                    HomeScreenView { url in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            activePlayerURL = url
                        }
                    }
                }
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                
                NavigationStack {
                    SettingScreenView()
                }
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
            }
            .background(TabBarStyler())
            
            if let url = activePlayerURL {
                PlayerView(url: url) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        activePlayerURL = nil
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }
        }
    }
}


#Preview {
    AppView()
}
