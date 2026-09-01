// The app target's import for the model *protocol* layer: `LanguageModel`,
// `LanguageModelSession`, `Tool`, `@Generable`, `Transcript`. teemoon builds
// its transports (HTTPTransport for remote, LiteRTTransport for on-device)
// against these.
//
// Deliberately does NOT re-export LiteRTLM. Both modules declare a `Tool` — a
// protocol in AnyLanguageModel, a different protocol in LiteRTLM — so
// re-exporting both makes every bare `any Tool` in the app ambiguous. LiteRTLM
// is linked anyway (see Package.swift) and imported directly by
// `LiteRTTransport.swift` and `LiteRTToolBridge.swift`: the only files that
// need it, and the ones where the name is qualified explicitly.
@_exported import AnyLanguageModel
