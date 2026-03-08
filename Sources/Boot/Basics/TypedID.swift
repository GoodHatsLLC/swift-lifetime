/// A type wrapper that makes bespoke ID types easy to make.
public protocol TypedID: Codable, Hashable, Sendable {
  /// The raw value in memory.
  ///
  /// - As the `raw` value is stored in memory. It must be `Sendable` to ensure the `TypedID` is.
  /// - If the `raw` value is `Hashable` the raw value will be used for `Hashable` conformance.
  /// - Note: If the `raw` value is not `Hashable` the Serialized value *must* be.
  /// - Tip: If the `raw` value is both `Hashable` and `Codable` it will be used as the `Serialized` value.
  associatedtype Raw: Sendable

  /// The representation of the ID which is written to disk.
  ///
  /// - To be written to disk the `Serialized` value must be `Codable` or `LosslessStringConvertible`.
  /// - Important: Iff the `Raw` type is not `Hashable` `Serialized` will be used if possible.
  associatedtype Serialized
  init(raw: Raw)
  var raw: Raw { get }
  var description: String { get }
  static func convert(raw: Raw) -> Serialized
  static func convert(serialized: Serialized) -> Raw?
}

/// Use `Raw` as `Serialized` if it already conforms to `Hashable` and `Codable`.
extension TypedID where Raw: Hashable, Raw: Codable, Raw == Serialized {
  public static func convert(raw: Raw) -> Serialized { raw }
  public static func convert(serialized: Serialized) -> Raw? { serialized }
}

extension TypedID where Raw == Serialized {
  public static func convert(raw: Raw) -> Serialized { raw }
  public static func convert(serialized: Serialized) -> Raw? { serialized }
}

extension TypedID where Raw: CustomStringConvertible {
  public var description: String { raw.description }
}

extension TypedID where Raw: CustomStringConvertible, Serialized: CustomStringConvertible {
  public var description: String { raw.description }
}

extension TypedID where Serialized: CustomStringConvertible {
  public var description: String { Self.convert(raw: raw).description }
}

/// Use `Raw` for hashing if possible
extension TypedID where Raw: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(raw)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.raw == rhs.raw
  }
}

/// Use `Raw` for hashing if possible — even if using `Serialized` is technically possible.
extension TypedID where Raw: Hashable, Serialized: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(raw)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.raw == rhs.raw
  }
}

/// Use `Serialized` for hashing if it is `Hashable` (and `Raw` is not).
extension TypedID where Serialized: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(Self.convert(raw: raw))
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    convert(raw: lhs.raw) == convert(raw: rhs.raw)
  }
}

/// Use `Serialized` for coding, without a `String` intermediate, if it is directly `Codable`.
extension TypedID where Serialized: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let serialized = try container.decode(Serialized.self)
    if let raw = Self.convert(serialized: serialized) {
      self.init(raw: raw)
    } else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: [],
          debugDescription:
            "\(Self.self) not convertible from decoded serialization value: \(serialized)"
        ))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(Self.convert(raw: raw))
  }
}

/// Use `Serialized` for coding, without a `String` intermediate, if it is directly `Codable`.
extension TypedID where Serialized: Codable & LosslessStringConvertible {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let serialized = try container.decode(Serialized.self)
    if let raw = Self.convert(serialized: serialized) {
      self.init(raw: raw)
    } else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: [],
          debugDescription:
            "\(Self.self) not convertible from decoded serialization value: \(serialized)"
        ))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(Self.convert(raw: raw))
  }
}

/// Use `Serialized`'s `LosslessStringConvertible` encoding  for coding if it lacks a direct `Codable` conformance
extension TypedID where Serialized: LosslessStringConvertible {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    if let serialized = Serialized(string),
      let raw = Self.convert(serialized: serialized)
    {
      self.init(raw: raw)
    } else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: [],
          debugDescription: "\(Self.self) not convertible from decoded string value: \(string)"
        ))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    let string = Self.convert(raw: raw).description
    var container = encoder.singleValueContainer()
    try container.encode(string)
  }
}

/// Use `Serialized`'s `LosslessStringConvertible` encoding  for coding if it lacks a direct `Codable` conformance
extension TypedID where Serialized == String {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    if let raw = Self.convert(serialized: string) {
      self.init(raw: raw)
    } else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: [],
          debugDescription: "\(Self.self) not convertible from decoded string value: \(string)"
        ))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    let string = Self.convert(raw: raw).description
    var container = encoder.singleValueContainer()
    try container.encode(string)
  }
}
