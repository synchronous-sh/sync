import SwiftUI
import SwiftData
import UIKit

struct HomeView: View {
    @State private var tab: AppTab = .home

    enum AppTab: Hashable {
        case home, videos, learn, news, you
    }

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .black
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.10)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().tintColor = .white
        UITabBar.appearance().unselectedItemTintColor = UIColor.white.withAlphaComponent(0.38)
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                ExploreHomeView()
            }
            .tabItem { Image(systemName: tab == .home ? "house.fill" : "house") }
            .tag(AppTab.home)

            NavigationStack {
                ForYouView()
            }
            .tabItem { Image(systemName: tab == .videos ? "play.fill" : "play") }
            .tag(AppTab.videos)

            NavigationStack {
                LearnView()
            }
            .tabItem { Image(systemName: tab == .learn ? "book.fill" : "book") }
            .tag(AppTab.learn)

            NavigationStack {
                NewsTabView()
            }
            .tabItem { Image(systemName: tab == .news ? "newspaper.fill" : "newspaper") }
            .tag(AppTab.news)

            NavigationStack {
                YouTabView()
            }
            .tabItem { Image(systemName: tab == .you ? "person.fill" : "person") }
            .tag(AppTab.you)
        }
        .toolbarBackground(.hidden, for: .tabBar)
    }
}

enum Route: Hashable {
    case search
    case save(UUID)
    case collection(UUID)
    case library
    case collections
    case entity(String)
    case recap
    case forYou
    case story(UUID)
    case settings
    case course(String)
    case lesson(String, Int)
}
