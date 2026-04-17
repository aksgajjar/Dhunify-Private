//
//  AppConfig.swift
//  Dhunify
//
//  App-wide runtime constants that aren't shipped in source control
//  production. Fill these before building.
//

import Foundation

enum AppConfig {
    /// Anthropic API key for the Aaj Ka Mix playlist generator.
    /// Get key from console.anthropic.com/settings/api-keys.
    static let claudeAPIKey = "" // not used
    /// OpenAI API key. Populate locally before building — never commit.
    /// Previous key was leaked via git history and rotated; generate a
    /// new one at platform.openai.com/api-keys.
    static let openAIAPIKey = ""
}
