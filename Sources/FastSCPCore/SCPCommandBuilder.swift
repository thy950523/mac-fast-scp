import Foundation

/// 构造 `scp` 的 argv。纯函数，便于单测。
/// 远端操作数形如 `<alias>:<remotePath>/<name>`；scp 以 argv 传递（非 shell），
/// 故文件名中的空格无需转义。
public enum SCPCommandBuilder {
    /// `scp -r <alias>:<remotePath>/<name> ... <localDest>/`
    /// - Parameters:
    ///   - alias: ssh config 别名
    ///   - remotePath: 远端目录（可带或不带尾斜杠、可为 `~`）
    ///   - names: 要拉取的条目名（文件或目录）
    ///   - localDest: 本地目标目录（需已存在）
    public static func pullArgs(alias: String, remotePath: String,
                                names: [String], localDest: URL) -> [String] {
        let base = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        var args = ["-r"]
        for name in names {
            args.append("\(alias):\(base)/\(name)")
        }
        args.append(localDest.path + "/")
        return args
    }
}
