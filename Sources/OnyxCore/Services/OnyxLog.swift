//
// OnyxLog.swift
//
// Responsibility: Structured logging via `os.Logger`. One subsystem
//                 (`com.onyx`) with several categories so Console.app
//                 can filter at fine granularity without losing the
//                 ability to see "everything Onyx logs" at once.
// Threading: Logger is thread-safe; the wrappers just forward.
//
// Console.app filter recipes:
//   subsystem:com.onyx                           — every Onyx event
//   subsystem:com.onyx category:ssh              — SSH mux + connect
//   subsystem:com.onyx category:session          — terminal sessions
//   subsystem:com.onyx category:poller           — CPU/docker fleet poll
//
// CLI alternative:
//   log stream --predicate 'subsystem == "com.onyx"'
//

import Foundation
import os

public enum OnyxLog {
    /// All events use this subsystem so Console / `log stream` can
    /// scope at the app level without false positives from AppKit/
    /// SceneKit/etc that happen to emit in our process.
    public static let subsystem = "com.onyx"

    public static let ssh      = Logger(subsystem: subsystem, category: "ssh")
    public static let session  = Logger(subsystem: subsystem, category: "session")
    public static let poller   = Logger(subsystem: subsystem, category: "poller")
    public static let store    = Logger(subsystem: subsystem, category: "store")
    public static let monitor  = Logger(subsystem: subsystem, category: "monitor")
}
