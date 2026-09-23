import Foundation

public enum RecordEmbeddingModelCatalog {
  public static let modelID = "qwen3-embedding-0.6b"
  public static let repository = "Qwen/Qwen3-Embedding-0.6B"
  public static let revision = "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3"
  public struct File: Sendable {
    public let path: String
    public let byteCount: Int
    public let sha256: String
  }
  public static let files: [File] = [
    .init(
      path: "config.json", byteCount: 727,
      sha256: "b5bf1f51fc45be473a54718cef92448d90a1be001bf9b9a44b8c7f10a19feaa9"),
    .init(
      path: "model.safetensors", byteCount: 1_191_586_416,
      sha256: "0437e45c94563b09e13cb7a64478fc406947a93cb34a7e05870fc8dcd48e23fd"),
    .init(
      path: "tokenizer.json", byteCount: 11_423_705,
      sha256: "def76fb086971c7867b829c23a26261e38d9d74e02139253b38aeb9df8b4b50a"),
    .init(
      path: "tokenizer_config.json", byteCount: 9_706,
      sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"),
    .init(
      path: "1_Pooling/config.json", byteCount: 313,
      sha256: "37bf193fa101f19101bfad9c31d3eb0f786e247b7b1e5cb7f007d730eed1ddbd"),
  ]
  public static var downloadByteCount: Int { files.reduce(0) { $0 + $1.byteCount } }
}
