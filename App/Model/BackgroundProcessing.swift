import BackgroundTasks
import Foundation
import os

/// Lets a run continue overnight while the phone charges.
///
/// iOS decides when a processing task runs; requiring external power keeps the work off battery.
/// Deleting originals is never done in the background, because the system confirmation dialog
/// needs the user; those items wait on the home screen.
enum BackgroundProcessing {
    static let identifier = "com.mediaslim.app.processing"
    private static let log = Logger(subsystem: "com.mediaslim.app", category: "background")

    @MainActor
    static func register(model: @escaping @MainActor () -> AppModel?) {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let box = TaskBox(task)
            Task { @MainActor in
                guard let model = model() else {
                    box.task.setTaskCompleted(success: false)
                    return
                }
                box.task.expirationHandler = {
                    Task { @MainActor in await model.suspendForBackgroundExpiry() }
                }
                if !model.isRunning { await model.resumeInterrupted() }
                await model.waitForRun()
                await model.refresh()
                if model.interrupted != nil { schedule() }
                box.task.setTaskCompleted(success: model.interrupted == nil)
            }
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.info("Background task not scheduled: \(String(describing: error), privacy: .private)")
        }
    }

    /// BGTask is not Sendable; it is only used on the main actor after this hop.
    private final class TaskBox: @unchecked Sendable {
        let task: BGProcessingTask
        init(_ task: BGProcessingTask) { self.task = task }
    }
}
