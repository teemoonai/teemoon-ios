//
//  OllamaBrowseLinks.swift
//  teemoon
//
//  Where the Ollama pull sheet sends someone to find a model, with the where sheet's filters where the site has
//  one (docs/IMAGES.md §4e). The shortlist has no image data, so it is never filtered.
//

import Foundation

enum OllamaBrowseLinks {
    static func ollama(_ filters: ModelBrowserQuery.Filter) -> String {
        filters.contains(.vision) ? "https://ollama.com/search?c=vision" : "https://ollama.com/search"
    }

    static func huggingFace(_ filters: ModelBrowserQuery.Filter) -> String {
        filters.contains(.vision)
            ? "https://huggingface.co/models?library=gguf&pipeline_tag=image-text-to-text&sort=trending"
            : "https://huggingface.co/models?library=gguf&sort=trending"
    }
}
