import Foundation

public enum EmbeddingVectorOperand: String, Equatable, Sendable {
  case left
  case right
}

public enum EmbeddingVectorError: Error, Equatable, Sendable {
  case emptyVector
  case dimensionMismatch(left: Int, right: Int)
  case nonFiniteValue(operand: EmbeddingVectorOperand, index: Int)
  case zeroMagnitude(operand: EmbeddingVectorOperand)
}

extension EmbeddingVectorError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .emptyVector:
      "Embedding vectors must not be empty."
    case .dimensionMismatch(let left, let right):
      "Embedding vector dimensions differ: \(left) and \(right)."
    case .nonFiniteValue(let operand, let index):
      "The \(operand.rawValue) embedding vector contains a non-finite value at index \(index)."
    case .zeroMagnitude(let operand):
      "The \(operand.rawValue) embedding vector has zero magnitude."
    }
  }
}

public enum EmbeddingVectorMath {
  public static func cosineSimilarity(
    _ left: [Float],
    _ right: [Float]
  ) throws -> Float {
    guard !left.isEmpty, !right.isEmpty else {
      throw EmbeddingVectorError.emptyVector
    }
    guard left.count == right.count else {
      throw EmbeddingVectorError.dimensionMismatch(
        left: left.count,
        right: right.count
      )
    }

    var dotProduct = 0.0
    var leftSquaredMagnitude = 0.0
    var rightSquaredMagnitude = 0.0

    for index in left.indices {
      let leftValue = left[index]
      guard leftValue.isFinite else {
        throw EmbeddingVectorError.nonFiniteValue(
          operand: .left,
          index: index
        )
      }

      let rightValue = right[index]
      guard rightValue.isFinite else {
        throw EmbeddingVectorError.nonFiniteValue(
          operand: .right,
          index: index
        )
      }

      let preciseLeft = Double(leftValue)
      let preciseRight = Double(rightValue)
      dotProduct += preciseLeft * preciseRight
      leftSquaredMagnitude += preciseLeft * preciseLeft
      rightSquaredMagnitude += preciseRight * preciseRight
    }

    guard leftSquaredMagnitude > 0 else {
      throw EmbeddingVectorError.zeroMagnitude(operand: .left)
    }
    guard rightSquaredMagnitude > 0 else {
      throw EmbeddingVectorError.zeroMagnitude(operand: .right)
    }

    let similarity =
      dotProduct
      / sqrt(leftSquaredMagnitude * rightSquaredMagnitude)
    return Float(min(1.0, max(-1.0, similarity)))
  }
}
