import Foundation

extension Scope {
  public var entities: EntityBindings {
    .init(scope: self)
  }

  public var components: ComponentBindings {
    .init(scope: self)
  }
}
