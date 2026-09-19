//
//  ListPriceSnapshot.swift
//  teemoon
//
//  GENERATED from OpenRouter's public /api/v1/models on 2026-09-18 by the
//  maintainers' release refresh — do not edit by hand; it is regenerated
//  before every release.
//
//  What this is for: a CUSTOM endpoint on a first-party vendor host (a user's
//  own OpenAI, Anthropic, Google, DeepSeek or Mistral key) lists through the
//  generic `/models` probe, which carries no price. This table fills the row
//  when the model id matches exactly. OpenRouter passes these vendors' list
//  prices through unchanged, so the number is the vendor's own. Anything not
//  matched stays blank — a blank row over a borrowed number.
//

import Foundation

enum ListPriceSnapshot {

    static let snapshotDate = "2026-09-18"

    /// Vendor host → the namespace its ids live under below.
    static let hosts: [String: String] = [
        "api.openai.com": "openai",
        "api.anthropic.com": "anthropic",
        "generativelanguage.googleapis.com": "google",
        "api.deepseek.com": "deepseek",
        "api.mistral.ai": "mistralai",
    ]

    /// "namespace/model" → "$input/$output" per 1M tokens.
    static let prices: [String: String] = [
        "anthropic/claude-3-haiku":                    "$0.25/$1.25",
        "anthropic/claude-fable-5":                    "$10.00/$50.00",
        "anthropic/claude-fable-5.1":                  "$10.00/$50.00",
        "anthropic/claude-haiku-4.5":                  "$1.00/$5.00",
        "anthropic/claude-opus-4":                     "$15.00/$75.00",
        "anthropic/claude-opus-4.1":                   "$15.00/$75.00",
        "anthropic/claude-opus-4.5":                   "$5.00/$25.00",
        "anthropic/claude-opus-4.6":                   "$5.00/$25.00",
        "anthropic/claude-opus-4.7":                   "$5.00/$25.00",
        "anthropic/claude-opus-4.8":                   "$5.00/$25.00",
        "anthropic/claude-opus-5":                     "$5.00/$25.00",
        "anthropic/claude-sonnet-4":                   "$3.00/$15.00",
        "anthropic/claude-sonnet-4.5":                 "$3.00/$15.00",
        "anthropic/claude-sonnet-4.6":                 "$3.00/$15.00",
        "anthropic/claude-sonnet-5":                   "$2.00/$10.00",
        "deepseek/deepseek-chat":                      "$0.32/$0.89",
        "deepseek/deepseek-chat-v3-0324":              "$0.25/$1.00",
        "deepseek/deepseek-chat-v3.1":                 "$0.25/$0.95",
        "deepseek/deepseek-r1":                        "$0.70/$2.50",
        "deepseek/deepseek-r1-0528":                   "$0.50/$2.15",
        "deepseek/deepseek-r1-distill-llama-70b":      "$0.80/$0.80",
        "deepseek/deepseek-v3.1-terminus":             "$0.27/$1.00",
        "deepseek/deepseek-v3.2":                      "$0.27/$0.40",
        "deepseek/deepseek-v3.2-exp":                  "$0.27/$0.41",
        "deepseek/deepseek-v4-flash":                  "$0.05/$0.09",
        "deepseek/deepseek-v4-flash-0731":             "$0.07/$0.18",
        "deepseek/deepseek-v4-flash-vision-exp":       "$0.22/$0.65",
        "deepseek/deepseek-v4-pro":                    "$0.57/$1.15",
        "deepseek/deepseek-v4-pro-0813":               "$0.58/$1.73",
        "deepseek/deepseek-v4.1-flash":                "$0.15/$0.60",
        "google/gemini-2.5-flash":                     "$0.30/$2.50",
        "google/gemini-2.5-flash-image":               "$0.30/$2.50",
        "google/gemini-2.5-flash-lite":                "$0.10/$0.40",
        "google/gemini-2.5-pro":                       "$1.25/$10.00",
        "google/gemini-2.5-pro-preview":               "$1.25/$10.00",
        "google/gemini-3-flash-preview":               "$0.50/$3.00",
        "google/gemini-3-pro-image":                   "$2.00/$12.00",
        "google/gemini-3-pro-image-preview":           "$2.00/$12.00",
        "google/gemini-3.1-flash-image":               "$0.50/$3.00",
        "google/gemini-3.1-flash-image-preview":       "$0.50/$3.00",
        "google/gemini-3.1-flash-lite":                "$0.25/$1.50",
        "google/gemini-3.1-flash-lite-image":          "$0.25/$1.50",
        "google/gemini-3.1-flash-lite-preview":        "$0.25/$1.50",
        "google/gemini-3.1-pro-preview":               "$2.00/$12.00",
        "google/gemini-3.1-pro-preview-customtools":   "$2.00/$12.00",
        "google/gemini-3.5-flash":                     "$1.50/$9.00",
        "google/gemini-3.5-flash-lite":                "$0.30/$2.50",
        "google/gemini-3.6-flash":                     "$0.75/$3.75",
        "google/gemini-3.7-flash":                     "$0.75/$3.75",
        "google/gemini-3.8-flash":                     "$0.75/$3.75",
        "google/gemma-2-27b-it":                       "$0.65/$0.65",
        "google/gemma-3-12b-it":                       "$0.05/$0.15",
        "google/gemma-3-27b-it":                       "$0.08/$0.45",
        "google/gemma-3-4b-it":                        "$0.05/$0.10",
        "google/gemma-4-26b-a4b-it":                   "$0.09/$0.30",
        "google/gemma-4-31b-it":                       "$0.09/$0.34",
        "mistralai/codestral-2508":                    "$0.30/$0.90",
        "mistralai/devstral-2512":                     "$0.40/$2.00",
        "mistralai/ministral-14b-2512":                "$0.20/$0.20",
        "mistralai/ministral-3b-2512":                 "$0.10/$0.10",
        "mistralai/ministral-8b-2512":                 "$0.15/$0.15",
        "mistralai/mistral-large":                     "$2.00/$6.00",
        "mistralai/mistral-large-2407":                "$2.00/$6.00",
        "mistralai/mistral-medium-3":                  "$0.40/$2.00",
        "mistralai/mistral-medium-3-5":                "$1.50/$7.50",
        "mistralai/mistral-medium-3.1":                "$0.40/$2.00",
        "mistralai/mistral-nemo":                      "$0.02/$0.03",
        "mistralai/mistral-saba":                      "$0.20/$0.60",
        "mistralai/mistral-small-24b-instruct-2501":   "$0.05/$0.08",
        "mistralai/mistral-small-2603":                "$0.15/$0.60",
        "mistralai/mistral-small-3.1-24b-instruct":    "$0.35/$0.56",
        "mistralai/mistral-small-3.2-24b-instruct":    "$0.09/$0.25",
        "mistralai/mixtral-8x22b-instruct":            "$2.00/$6.00",
        "mistralai/voxtral-small-24b-2507":            "$0.10/$0.30",
        "openai/gpt-3.5-turbo":                        "$0.50/$1.50",
        "openai/gpt-3.5-turbo-0613":                   "$1.00/$2.00",
        "openai/gpt-3.5-turbo-16k":                    "$3.00/$4.00",
        "openai/gpt-3.5-turbo-instruct":               "$1.50/$2.00",
        "openai/gpt-4":                                "$30.00/$60.00",
        "openai/gpt-4-turbo":                          "$10.00/$30.00",
        "openai/gpt-4.1":                              "$2.00/$8.00",
        "openai/gpt-4.1-mini":                         "$0.40/$1.60",
        "openai/gpt-4.1-nano":                         "$0.10/$0.40",
        "openai/gpt-4o":                               "$2.50/$10.00",
        "openai/gpt-4o-2024-05-13":                    "$5.00/$15.00",
        "openai/gpt-4o-2024-08-06":                    "$2.50/$10.00",
        "openai/gpt-4o-2024-11-20":                    "$2.50/$10.00",
        "openai/gpt-4o-mini":                          "$0.15/$0.60",
        "openai/gpt-4o-mini-2024-07-18":               "$0.15/$0.60",
        "openai/gpt-5":                                "$1.25/$10.00",
        "openai/gpt-5-image":                          "$10.00/$10.00",
        "openai/gpt-5-image-mini":                     "$2.50/$2.00",
        "openai/gpt-5-mini":                           "$0.25/$2.00",
        "openai/gpt-5-nano":                           "$0.05/$0.40",
        "openai/gpt-5-pro":                            "$15.00/$120.00",
        "openai/gpt-5.1":                              "$1.25/$10.00",
        "openai/gpt-5.1-codex":                        "$1.25/$10.00",
        "openai/gpt-5.1-codex-max":                    "$1.25/$10.00",
        "openai/gpt-5.1-codex-mini":                   "$0.25/$2.00",
        "openai/gpt-5.2":                              "$1.75/$14.00",
        "openai/gpt-5.2-chat":                         "$1.75/$14.00",
        "openai/gpt-5.2-codex":                        "$1.75/$14.00",
        "openai/gpt-5.2-pro":                          "$21.00/$168.00",
        "openai/gpt-5.3-codex":                        "$1.75/$14.00",
        "openai/gpt-5.4":                              "$2.50/$15.00",
        "openai/gpt-5.4-image-2":                      "$8.00/$15.00",
        "openai/gpt-5.4-mini":                         "$0.75/$4.50",
        "openai/gpt-5.4-nano":                         "$0.20/$1.25",
        "openai/gpt-5.4-pro":                          "$30.00/$180.00",
        "openai/gpt-5.5":                              "$5.00/$30.00",
        "openai/gpt-5.5-pro":                          "$30.00/$180.00",
        "openai/gpt-5.6-luna":                         "$0.20/$1.20",
        "openai/gpt-5.6-luna-pro":                     "$0.20/$1.20",
        "openai/gpt-5.6-sol":                          "$2.00/$10.00",
        "openai/gpt-5.6-sol-pro":                      "$2.00/$10.00",
        "openai/gpt-5.6-terra":                        "$2.00/$12.00",
        "openai/gpt-5.6-terra-pro":                    "$2.00/$12.00",
        "openai/gpt-6-astra":                          "$10.00/$50.00",
        "openai/gpt-6-astra-pro":                      "$10.00/$50.00",
        "openai/gpt-audio":                            "$2.50/$10.00",
        "openai/gpt-audio-mini":                       "$0.60/$2.40",
        "openai/gpt-chat-latest":                      "$5.00/$30.00",
        "openai/gpt-oss-120b":                         "$0.15/$0.60",
        "openai/gpt-oss-20b":                          "$0.03/$0.13",
        "openai/gpt-oss-safeguard-20b":                "$0.08/$0.30",
        "openai/o1":                                   "$15.00/$60.00",
        "openai/o1-pro":                               "$150.00/$600.00",
        "openai/o3":                                   "$2.00/$8.00",
        "openai/o3-mini":                              "$1.10/$4.40",
        "openai/o3-mini-high":                         "$1.10/$4.40",
        "openai/o3-pro":                               "$20.00/$80.00",
        "openai/o4-mini":                              "$1.10/$4.40",
        "openai/o4-mini-high":                         "$1.10/$4.40",
    ]

    /// The list price for `modelID` as served by `host`, or "" when the host
    /// is not a first-party vendor here or the id has no exact entry.
    static func price(host: String?, modelID: String) -> String {
        guard let host = host?.lowercased(), let namespace = hosts[host] else { return "" }
        var slug = modelID.lowercased()
        // Google's OpenAI-compat list prefixes every id with "models/".
        if slug.hasPrefix("models/") { slug = String(slug.dropFirst("models/".count)) }
        if let exact = prices[namespace + "/" + slug] { return exact }
        // Anthropic writes versions with a dash on its own API
        // ("claude-opus-4-8") and OpenRouter with a dot ("claude-opus-4.8").
        let dashed = slug.replacingOccurrences(of: ".", with: "-")
        let prefix = namespace + "/"
        return prices.first { entry in
            entry.key.hasPrefix(prefix)
                && entry.key.dropFirst(prefix.count).replacingOccurrences(of: ".", with: "-") == dashed
        }?.value ?? ""
    }
}
