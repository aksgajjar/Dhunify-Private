//
//  SearchSongsUseCase.swift
//  Dhunify
//
//  Validates a search query and delegates to the SongRepository.
//

import Foundation

enum SearchSongsError: LocalizedError {
    case emptyQuery

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Please enter something to search for."
        }
    }
}

struct SearchSongsUseCase {
    private let repository: SongRepository

    init(repository: SongRepository) {
        self.repository = repository
    }

    func execute(query: String) async throws -> [Song] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SearchSongsError.emptyQuery
        }
        return try await repository.search(query: trimmed)
    }
}
