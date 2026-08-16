//
//  DPCore.swift
//  DriverProKit
//
//  Target responsibility
//  ────────────────────
//  DPCore defines *what a remote file system is* in DriverPro, without knowing about any particular
//  protocol and without knowing that a user interface exists.
//
//  It owns:
//    • the model types — `RemotePath`, `RemoteItem`, `POSIXPermissions`, `Host`
//    • the `Session` protocol that every backend (SFTP, WebDAV, S3, FTP) implements
//    • `SessionCapabilities`, which is how callers ask what a backend can actually do
//    • `SessionDelegate`, the channel by which a backend asks a human a question
//
//  It may import: Foundation. Nothing else.
//  It may NOT import: SwiftUI, AppKit, Citadel, Soto, NIO, or any DP* target.
//
//  The rule is one-directional: protocol targets depend on DPCore, DPCore depends on none of them. If
//  you ever feel the urge to `import DPProtocolSFTP` here, the abstraction is wrong — fix the
//  abstraction, not the import.
//
