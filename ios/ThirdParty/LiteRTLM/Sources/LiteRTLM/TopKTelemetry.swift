// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CLiteRTLM
import Foundation

/// One candidate in a diagnostic top-k snapshot.
public struct TopKTelemetryCandidate: Sendable, Equatable {
  public let tokenID: Int
  public let logit: Float
  public let probability: Float
}

/// A compact diagnostic snapshot captured before sampling one decoded token.
///
/// Probabilities and entropy are normalized only across `candidates` at the
/// fixed `metricTemperature` of 1.0. They are not full-vocabulary metrics.
public struct TopKTelemetryEvent: Sendable, Equatable {
  public let abiVersion: UInt32
  public let batchIndex: Int
  public let sequenceIndex: Int
  public let sampledTokenID: Int
  public let topKEntropy: Float
  public let top1Top2Margin: Float
  public let metricTemperature: Float
  public let candidates: [TopKTelemetryCandidate]
}

/// Buffered telemetry copied synchronously from native callbacks.
public struct TopKTelemetryDrain: Sendable, Equatable {
  public let events: [TopKTelemetryEvent]
  public let droppedEventCount: Int
}

final class TopKTelemetryCallbackContext: @unchecked Sendable {
  private static let maximumBufferedEventCount = 8_192

  let events: AsyncStream<TopKTelemetryEvent>
  private let continuation: AsyncStream<TopKTelemetryEvent>.Continuation
  private let lock = NSLock()
  private var bufferedEvents: [TopKTelemetryEvent] = []
  private var droppedEventCount = 0

  init() {
    var capturedContinuation: AsyncStream<TopKTelemetryEvent>.Continuation?
    events = AsyncStream { continuation in
      capturedContinuation = continuation
    }
    continuation = capturedContinuation!
  }

  func finish() {
    continuation.finish()
  }

  func yield(_ event: TopKTelemetryEvent) {
    lock.lock()
    if bufferedEvents.count < Self.maximumBufferedEventCount {
      bufferedEvents.append(event)
    } else {
      droppedEventCount += 1
    }
    lock.unlock()
    continuation.yield(event)
  }

  func drain() -> TopKTelemetryDrain {
    lock.lock()
    defer { lock.unlock() }
    let drain = TopKTelemetryDrain(
      events: bufferedEvents,
      droppedEventCount: droppedEventCount
    )
    bufferedEvents.removeAll(keepingCapacity: true)
    droppedEventCount = 0
    return drain
  }
}

let topKTelemetryCallback:
  @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<LiteRtLmTopKTelemetryEvent>?) -> Void =
  { userData, eventPointer in
    guard let userData, let eventPointer else {
      return
    }

    let nativeEvent = eventPointer.pointee
    let count = max(0, Int(nativeEvent.candidate_count))
    var candidates: [TopKTelemetryCandidate] = []
    candidates.reserveCapacity(count)
    if let nativeCandidates = nativeEvent.candidates {
      for index in 0..<count {
        let candidate = nativeCandidates[index]
        candidates.append(
          TopKTelemetryCandidate(
            tokenID: Int(candidate.token_id),
            logit: candidate.logit,
            probability: candidate.probability
          ))
      }
    }

    let event = TopKTelemetryEvent(
      abiVersion: nativeEvent.abi_version,
      batchIndex: Int(nativeEvent.batch_index),
      sequenceIndex: Int(nativeEvent.sequence_index),
      sampledTokenID: Int(nativeEvent.sampled_token_id),
      topKEntropy: nativeEvent.top_k_entropy,
      top1Top2Margin: nativeEvent.top1_top2_margin,
      metricTemperature: nativeEvent.metric_temperature,
      candidates: candidates
    )
    Unmanaged<TopKTelemetryCallbackContext>
      .fromOpaque(userData)
      .takeUnretainedValue()
      .yield(event)
  }

let topKTelemetryReleaseCallback:
  @convention(c) (UnsafeMutableRawPointer?) -> Void = { userData in
    guard let userData else {
      return
    }
    Unmanaged<TopKTelemetryCallbackContext>
      .fromOpaque(userData)
      .release()
  }
