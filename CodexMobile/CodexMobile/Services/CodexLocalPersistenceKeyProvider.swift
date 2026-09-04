// FILE: CodexLocalPersistenceKeyProvider.swift
// Purpose: Provides one process-cached Keychain key for encrypted local app data.
// Layer: Service Persistence
// Exports: CodexLocalPersistenceKeyProvider
// Depends on: CryptoKit, Foundation, SecureStore

import CryptoKit
import Foundation
import Security

nonisolated enum CodexLocalPersistenceKeyProvider {
    private static let storage = Storage()

    static func historyKey() -> SymmetricKey {
        storage.historyKey()
    }

    static func stableIndex(for value: String) -> String {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8),
            using: storage.indexKey()
        )
        return Data(authenticationCode).base64EncodedString()
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedHistoryKey: SymmetricKey?

        func indexKey() -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: historyKey(),
                salt: Data("cn.syggu.remodex.cache-index".utf8),
                info: Data(),
                outputByteCount: 32
            )
        }

        func historyKey() -> SymmetricKey {
            lock.lock()
            defer { lock.unlock() }

            if let cachedHistoryKey {
                return cachedHistoryKey
            }
            if let storedKey = SecureStore.readData(for: CodexSecureKeys.messageHistoryKey) {
                let key = SymmetricKey(data: storedKey)
                cachedHistoryKey = key
                return key
            }

            let key = SymmetricKey(size: .bits256)
            let keyData = key.withUnsafeBytes { Data($0) }
            SecureStore.writeData(
                keyData,
                for: CodexSecureKeys.messageHistoryKey,
                accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            )
            cachedHistoryKey = key
            return key
        }
    }
}
