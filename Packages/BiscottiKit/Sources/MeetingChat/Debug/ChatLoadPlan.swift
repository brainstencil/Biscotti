#if DEBUG
    import Foundation

    /// A measurement plan for `ChatLoadDriver`: when to start, which policy
    /// mode to force, and the questions to ask. The plans are in
    /// `Tools/chat_bench/plans`. Debug builds only.
    public struct ChatLoadPlan: Decodable, Equatable, Sendable {
        public enum Mode: String, Decodable, Sendable {
            case concurrent
            case waitForStop

            var policyMode: ChatResourcePolicy.Mode {
                switch self {
                case .concurrent: .concurrent
                case .waitForStop: .waitForStop
                }
            }
        }

        /// The event that starts the plan's clock.
        public enum Start: String, Decodable, Sendable {
            case recordingStart
            case recordingStop
        }

        /// A recording the driver makes itself, for unattended runs.
        public struct Recording: Decodable, Equatable, Sendable {
            /// From the end of the app's launch to Record.
            public var startAfterSeconds: Double
            /// From the recording's start to Stop.
            public var durationSeconds: Double
        }

        /// The launch argument followed by the plan file's path.
        public static let launchArgument = "-chatLoadTest"

        public var name: String
        /// Forced on the resource policy for the run, whatever this Mac's memory.
        public var mode: Mode
        public var startAfter: Start
        /// Forced on the resource policy for the run: whether the model closes
        /// after each answer during a recording, as on Macs under
        /// `closeAfterAnswerBelowMemory`. Nil keeps this Mac's policy. The E2B
        /// run sets it, because only Macs under 24 GB use E2B.
        public var closeModelAfterAnswer: Bool?
        /// From the start to the first question.
        public var startDelaySeconds: Double
        /// Between two questions' due times. A question whose time comes while
        /// an answer runs waits for it.
        public var intervalSeconds: Double
        public var questions: [String]
        /// The catalog model selected for the run, as in Settings (for
        /// example `gemma-4-e2b`). Nil keeps the model selected in Settings.
        public var model: String?
        /// The recording the driver starts and stops. Nil waits for one
        /// started in the app.
        public var record: Recording?

        /// When question `index` (from 0) is due, after the plan's start.
        func dueTime(ofQuestion index: Int) -> Duration {
            .seconds(startDelaySeconds + intervalSeconds * Double(index))
        }

        static func load(from url: URL) throws -> ChatLoadPlan {
            try JSONDecoder().decode(ChatLoadPlan.self, from: Data(contentsOf: url))
        }

        /// The plan file's path that follows `launchArgument`, if any.
        static func path(in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: launchArgument), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
    }

    extension ChatResourcePolicy {
        /// This policy with its mode, and optionally whether the model closes
        /// after each answer during a recording, forced on any Mac: each
        /// memory limit goes to the top or to zero. For the chat load driver only.
        func override(mode: Mode, closesAfterAnswer: Bool? = nil) -> ChatResourcePolicy {
            var policy = self
            policy.waitForStopMaximumMemory = mode == .waitForStop ? .max : 0
            if let closesAfterAnswer {
                policy.closeAfterAnswerBelowMemory = closesAfterAnswer ? .max : 0
            }
            return policy
        }
    }
#endif
