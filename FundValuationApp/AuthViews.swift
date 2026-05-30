import SwiftUI
import UIKit

struct AuthFlowView: View {
    enum Mode {
        case login
        case register
        case forgot
    }

    @ObservedObject var session: SessionViewModel

    @State private var mode: Mode = .login
    @State private var backendURLDraft = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var resetCode = ""
    @State private var resetRequested = false
    @State private var showServer = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
        case confirmPassword
        case resetCode
        case backendURL
    }

    var body: some View {
        ZStack {
            Color(hex: 0x1C1C1E).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    formCard
                    if AppEnvironment.isDebug {
                        serverCard
                    }
                    footerActions
                }
                .padding(.horizontal, 22)
                .padding(.top, 72)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            backendURLDraft = session.backendURL
            if focusedField == nil {
                focusedField = .email
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FinMate")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.72))
        }
    }

    private var formCard: some View {
        VStack(spacing: 14) {
            field("邮箱", text: $email, keyboard: .emailAddress, field: .email)
            if mode != .forgot || resetRequested {
                secureField(mode == .forgot ? "新密码" : "密码", text: $password, field: .password)
            } else if mode == .forgot {
                EmptyView()
            }
            if mode == .register {
                secureField("确认密码", text: $confirmPassword, field: .confirmPassword)
            }
            if mode == .forgot && resetRequested {
                field("验证码", text: $resetCode, keyboard: .numberPad, field: .resetCode)
            }

            if !session.statusMessage.isEmpty {
                Text(session.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 8) {
                    if session.isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(primaryTitle)
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 14).fill(canSubmit ? Color(hex: 0x2B7FFF) : Color(hex: 0x2C2C2E)))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit || session.isWorking)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(hex: 0x0A0A0A))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0x262626).opacity(0.2), lineWidth: 1))
        )
    }

    private var serverCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showServer.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "server.rack")
                    Text("账号服务")
                    Spacer()
                    Text(session.backendURL)
                        .lineLimit(1)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.55))
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showServer ? 90 : 0))
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(hex: 0xFAFAFA).opacity(0.82))
                .padding(.horizontal, 16)
                .frame(height: 50)
            }
            .buttonStyle(.plain)

            if showServer {
                Divider().overlay(Color(hex: 0x262626).opacity(0.2))
                VStack(alignment: .leading, spacing: 8) {
                    field("Backend URL", text: $backendURLDraft, keyboard: .URL, field: .backendURL)
                    backendQuickActions
                    Text("模拟器用 `http://127.0.0.1:8787`。真机用 `http://Mac.local:8787` 或电脑局域网 IP。后端必须用 `0.0.0.0` 启动。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.6))
                }
                .padding(16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(hex: 0x0A0A0A))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0x262626).opacity(0.2), lineWidth: 1))
        )
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            Button(mode == .login ? "注册账号" : "返回登录") {
                switchMode(mode == .login ? .register : .login)
            }
            Spacer()
            Button(mode == .forgot ? "返回登录" : "找回密码") {
                switchMode(mode == .forgot ? .login : .forgot)
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color(hex: 0x2B7FFF))
    }

    private var subtitle: String {
        switch mode {
        case .login: return "登录后同步基金和美股持仓。"
        case .register: return "使用邮箱注册，不需要邮箱验证。"
        case .forgot: return resetRequested ? "输入邮箱验证码并设置新密码。" : "验证码会发送到注册邮箱。"
        }
    }

    private var primaryTitle: String {
        switch mode {
        case .login: return "登录"
        case .register: return "注册并登录"
        case .forgot: return resetRequested ? "重置密码并登录" : "发送验证码"
        }
    }

    private var canSubmit: Bool {
        let hasEmail = email.contains("@") && email.contains(".")
        switch mode {
        case .login:
            return hasEmail && password.count >= 8
        case .register:
            return hasEmail && password.count >= 8 && password == confirmPassword
        case .forgot:
            if resetRequested {
                return hasEmail && resetCode.count == 6 && password.count >= 8
            }
            return hasEmail
        }
    }

    private func submit() async {
        syncBackendURL()
        switch mode {
        case .login:
            _ = await session.login(email: email, password: password)
        case .register:
            _ = await session.register(email: email, password: password)
        case .forgot:
            if resetRequested {
                _ = await session.confirmPasswordReset(email: email, code: resetCode, newPassword: password)
            } else if await session.requestPasswordReset(email: email) {
                resetRequested = true
                password = ""
            }
        }
    }

    private func switchMode(_ next: Mode) {
        mode = next
        password = ""
        confirmPassword = ""
        resetCode = ""
        resetRequested = false
        session.statusMessage = ""
    }

    private func syncBackendURL() {
        let trimmed = backendURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != session.backendURL {
            session.backendURL = trimmed
        }
    }

    private var backendQuickActions: some View {
        HStack(spacing: 8) {
            backendQuickButton("模拟器", value: SessionViewModel.simulatorBackendURL)
            backendQuickButton("真机", value: SessionViewModel.deviceBackendURL)
        }
    }

    private func backendQuickButton(_ title: String, value: String) -> some View {
        Button {
            backendURLDraft = value
            session.backendURL = value
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: 0xDBEAFE))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x1C398E).opacity(0.45)))
        }
        .buttonStyle(.plain)
    }

    private func field(_ label: String, text: Binding<String>, keyboard: UIKeyboardType, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.34)
                .textCase(.uppercase)
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.6))
            TextField("", text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .focused($focusedField, equals: field)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(fieldBackground)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = field
        }
    }

    private func secureField(_ label: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.34)
                .textCase(.uppercase)
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.6))
            SecureField("", text: text)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .focused($focusedField, equals: field)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(fieldBackground)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = field
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(hex: 0x2C2C2E))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0x262626).opacity(0.2), lineWidth: 1))
    }
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8) & 0xff) / 255
        let b = Double(hex & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
