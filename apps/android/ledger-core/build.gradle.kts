import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Pure Kotlin, no Android: crypto, envelope, events, reducer, balances.
// Implements docs/PROTOCOL.md, verified against spec/vectors.
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
    api(libs.serialization.json)
    implementation(libs.bouncycastle)
    testImplementation(kotlin("test"))
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.launcher)
}

tasks.test {
    useJUnitPlatform()
    // The same JSON every implementation runs.
    systemProperty("vectors.dir", rootDir.resolve("../../spec/vectors").canonicalPath)
}
