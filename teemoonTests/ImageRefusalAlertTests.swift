//
//  ImageRefusalAlertTests.swift
//  teemoonTests
//
//  the maintainer 2026-11-12: the send-refusal alert goes short (DRAFT strings, Android the same).
//

import Testing
@testable import teemoon

@Suite("Image refusal alert — words")
struct ImageRefusalAlertTests {

    @Test func withTextItOffersAModelTheTextOrCancel() {
        let alert = ImageRefusalAlert(modelName: "GLM 5.3 Flash", hasText: true)
        #expect(alert.title == "glm 5.3 flash can't see images")
        #expect(alert.message == "your message wasn't sent. pick a model that can, or send just the text.")
        #expect(alert.buttons == ["choose model", "send text only", "cancel"])
    }

    /// A phone model this phone can never give the memory: the permanent line, never "can't see" (§4b, Android parity).
    @Test func aPhoneModelThatCantFitSaysThePhoneCant() {
        let alert = ImageRefusalAlert(phoneModel: "gemma 4 e4b", smaller: "gemma 4 e2b")
        #expect(alert.title == "this phone doesn't have enough memory for images with gemma 4 e4b.")
        #expect(alert.buttons == ["use gemma 4 e2b", "ok"])
        #expect(ImageRefusalAlert(phoneModel: "gemma 4 e4b", smaller: nil).buttons == ["ok"])
    }

    @Test func withoutTextItOffersAModelOrCancel() {
        let alert = ImageRefusalAlert(modelName: "fake-model", hasText: false)
        #expect(alert.title == "fake-model can't see images")
        #expect(alert.message == "your message wasn't sent. pick a model that can.")
        #expect(alert.buttons == ["choose model", "cancel"])
    }
}
