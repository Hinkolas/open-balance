pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "open-balance-android"

// Pure Kotlin, no Android: crypto, envelope, events, reducer, balances
// (docs/PROTOCOL.md, verified against spec/vectors). Mirrors LedgerCore.
include(":ledger-core")
// Server client, invite links, outbox, cache, live updates. Mirrors LedgerSync.
include(":ledger-sync")
// The Compose app.
include(":app")
