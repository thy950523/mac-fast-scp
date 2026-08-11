import Foundation

/// 构造 `scp` 的 argv。纯函数，便于单测。
/// 远端操作数形如 `<alias>:<remotePath>/<name>`；scp 以 argv 传递（非 shell），
/// 故文件名中的空格无需转义。
public enum SCPCommandBuilder {
    /// 强制 legacy SCP 协议。
    ///
    /// 不加 `-O` 时 scp 走 SFTP：进度行照常每秒重绘，但其中的已传输字节数
    /// **不递增**（实测 8MB 文件整个传输过程卡在 `3% 255KB`，末尾直接跳
    /// 100%）。加上 `-O` 后同一文件稳定输出 3% → 6% → 8% …。
    ///
    /// 注：早先代码注释称「macOS 的 scp 静默忽略 -O」，在 OpenSSH 10.2p1
    /// (macOS 26.5) 上不成立 —— `-O` 工作正常。
    public static let legacyProtocolFlag = "-O"

    /// `scp -r -O <alias>:<remotePath>/<name> ... <localDest>/`
    /// - Parameters:
    ///   - alias: ssh config 别名
    ///   - remotePath: 远端目录（可带或不带尾斜杠、可为 `~`）
    ///   - names: 要拉取的条目名（文件或目录）
    ///   - localDest: 本地目标目录（需已存在）
    public static func pullArgs(alias: String, remotePath: String,
                                names: [String], localDest: URL) -> [String] {
        let base = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        var args = ["-r", legacyProtocolFlag]
        for name in names {
            args.append("\(alias):\(base)/\(name)")
        }
        args.append(localDest.path + "/")
        return args
    }
}
