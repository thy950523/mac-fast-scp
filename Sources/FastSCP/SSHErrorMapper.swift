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
            case .cancelled: return "已取消"
            }
        } else {
            raw = error.localizedDescription
        }
        let lower = raw.lowercased()

        // "publickey" specifically indicates SSH key authentication failure.
        if lower.contains("publickey") {
            return "认证失败：SSH 密钥被拒绝。请检查密钥是否已加入 ssh-agent，或在 ~/.ssh/config 中正确配置 IdentityFile。"
        }
        // scp (SFTP mode) failing to open the REMOTE destination file: almost
        // always a read-only file of the same name already sitting at the
        // target, or an unwritable remote directory. Distinct from a local read.
        if lower.contains("dest open") && lower.contains("permission denied") {
            return "无法写入远程目标：远程目录无写权限，或已存在同名只读文件无法覆盖。请删除远程同名文件（或改其权限）后重试。"
        }
        if lower.contains("permission denied") {
            return "权限不足。若发送的是受保护位置（桌面、文稿、下载等）的文件，请在「系统设置 › 隐私与安全性」中允许 FastSCP 访问该文件夹后重试；否则请检查远程目标路径的写权限。"
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
