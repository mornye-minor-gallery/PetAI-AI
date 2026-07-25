import Testing

@testable import EdgeLLM

@Test
func cosineSimilarityRecognizesVectorDirection() throws {
  let reference: [Float] = [1, 0]

  #expect(
    try EmbeddingVectorMath.cosineSimilarity(reference, [1, 0])
      == 1
  )
  #expect(
    try EmbeddingVectorMath.cosineSimilarity(reference, [0, 1])
      == 0
  )
  #expect(
    try EmbeddingVectorMath.cosineSimilarity(reference, [-1, 0])
      == -1
  )
}

@Test
func cosineSimilarityRejectsEmptyAndMismatchedVectors() {
  #expect(throws: EmbeddingVectorError.emptyVector) {
    try EmbeddingVectorMath.cosineSimilarity([], [])
  }
  #expect(
    throws: EmbeddingVectorError.dimensionMismatch(left: 2, right: 1)
  ) {
    try EmbeddingVectorMath.cosineSimilarity([1, 0], [1])
  }
}

@Test
func cosineSimilarityRejectsNonFiniteValues() {
  #expect(
    throws: EmbeddingVectorError.nonFiniteValue(
      operand: .left,
      index: 1
    )
  ) {
    try EmbeddingVectorMath.cosineSimilarity([1, .nan], [1, 0])
  }
  #expect(
    throws: EmbeddingVectorError.nonFiniteValue(
      operand: .right,
      index: 0
    )
  ) {
    try EmbeddingVectorMath.cosineSimilarity([1, 0], [.infinity, 0])
  }
}

@Test
func cosineSimilarityRejectsZeroMagnitudeVectors() {
  #expect(
    throws: EmbeddingVectorError.zeroMagnitude(operand: .left)
  ) {
    try EmbeddingVectorMath.cosineSimilarity([0, 0], [1, 0])
  }
  #expect(
    throws: EmbeddingVectorError.zeroMagnitude(operand: .right)
  ) {
    try EmbeddingVectorMath.cosineSimilarity([1, 0], [0, 0])
  }
}
