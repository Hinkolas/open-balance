import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Talks to an Open Balance server: signed requests, invite links,
// credentials, the local ledger cache, outbox and live updates. No Android
// dependencies, so it runs in JVM tests against a real server.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget = JvmTarget.JVM_17 }
}

dependencies {
    api(project(":ledger-core"))
    api(libs.coroutines.core)
    api(libs.okhttp)
    testImplementation(kotlin("test"))
    testImplementation(libs.coroutines.test)
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.launcher)
}

tasks.test {
    useJUnitPlatform()
    // End to end against a running server; skipped without OB_TEST_SERVER.
    listOf("OB_TEST_SERVER", "OB_TEST_OWNER_TOKEN").forEach { name ->
        System.getenv(name)?.let { environment(name, it) }
    }
}
