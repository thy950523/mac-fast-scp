import Foundation
import FastSCPCore

/// Maps raw SSH/SCP stderr to user-friendly Chinese messages.
enum SSHErrorMapper {
    static func friendlyMessage(for error: Error) -> String {
        let raw: String
        if let e = error as? SSHError {
            switch e {
            case .listingFailed(_, let s): raw = s
            case .transferFailed(let s): raw = s
            }
        } else {
            raw = error.localizedDescription
        }
        let lower = raw.lowercased()

        // "publickey" specifically indicates SSH key authentication failure.
        if lower.contains("publickey") {
            return "认证失败：SSH 密钥被拒绝。请检查密钥是否已加入 ssh-agent，或在 ~/.ssh/config 中正确配置 IdentityFile。"
        }
        if lower.contains("permission denied") {
            return "权限不足：无法写入远程目录。请检查目标路径的权限。"
        }
        if lower.contains("connection refused") {
            return "连接被拒绝：目标服务器的 SSH 端口未开放。"
        }
        if lower.contains("no route to host") || lower.contains("network is unreachable") {
            return "网络不可达：无法连接到目标服务器。"
        }
        if lower.contains("operation timed out") || lower.contains("connection timed out") || lower.contains("timeout") {
            return "连接超时：服务器无响应。"
        }
        if lower.contains("could not resolve hostname") || lower.contains("nodename nor servname") {
            return "无法解析主机名：请检查 ~/.ssh/config 中的 HostName 配置。"
        }
        if lower.contains("host key verification failed") {
            return "主机密钥验证失败：服务器的主机密钥已变更或不在 known_hosts 中。"
        }
        if lower.contains("no such file or directory") {
            return "远程路径或本地文件不存在。"
        }
        if lower.contains("broken pipe") || lower.contains("connection reset") {
            return "连接中断：传输过程中连接被断开。"
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
