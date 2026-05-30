import Foundation
import SwiftUI

/// 应用构建环境判断
enum AppEnvironment {
    /// 当前是否为 Debug/开发模式
    static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// 后端服务生产地址
    static var productionBackendURL: String {
        "https://thsbridge.zeabur.app"
    }
}

// MARK: - 共享颜色工具，全局统一，避免重复计算

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8) & 0xff) / 255
        let b = Double(hex & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    // 页面常用颜色常量
    static let appBackground = Color(hex: 0x1C1C1E)
    static let cardBackground = Color(hex: 0x0A0A0A)
    static let fieldBackground = Color(hex: 0x2C2C2E)
    static let accentBlue = Color(hex: 0x2B7FFF)
    static let secondaryText = Color(hex: 0xA1A1A1)
    static let foregroundWhite = Color(hex: 0xFAFAFA)
    static let borderGray = Color(hex: 0x262626).opacity(0.2)
    static let destructiveRed = Color(hex: 0xFB2C36)
    static let hintGreen = Color(hex: 0x34C759)
}
