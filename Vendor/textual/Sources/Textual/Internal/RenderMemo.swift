import SwiftUI

// TEEMOON PATCH — this whole file. See ../../../VENDORING.md.
//
// The rendering path resolves several things from its inputs: the markdown
// parse, the inline styling, the `Text` build. Upstream kept each in `@State`
// seeded from `.onChange(of:initial: true)`, which runs when the view APPEARS
// — after the layout system has already asked how big it is. The first
// measurement of a freshly built row therefore described an EMPTY document,
// and the real height landed a pass later as a resize. Once per row per
// appearance, that is the scroll jank.
//
// The fix is to resolve during body evaluation. That needs somewhere to keep
// the result which is writable from `body`, and `@State` is not: assigning to
// it there is a mutation during evaluation. A reference type held BY `@State`
// is — the object's identity is what SwiftUI stores, and writing through it is
// the same "populate a cache while rendering" pattern as an `NSCache`.
//
// So: one value, memoized against the input it was derived from. A recycled
// view whose input has changed recomputes rather than showing the previous
// row's content, and nothing is ever computed twice for the same input.

/// A single memoized derivation, keyed on the input it came from.
@MainActor
final class RenderMemo<Key: Equatable, Value> {
  private var key: Key?
  private var value: Value?

  init() {}

  /// The memoized value for `key`, deriving it if this is a new input.
  func value(for key: Key, derive: (Key) -> Value) -> Value {
    if let value, self.key == key { return value }
    let derived = derive(key)
    self.key = key
    self.value = derived
    return derived
  }

  /// The memoized value, if one has been derived for `key`.
  func current(for key: Key) -> Value? {
    guard let value, self.key == key else { return nil }
    return value
  }
}
