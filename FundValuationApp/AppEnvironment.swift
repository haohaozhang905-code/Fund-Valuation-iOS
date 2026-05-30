import Foundation

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
