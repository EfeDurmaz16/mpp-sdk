plugins {
    kotlin("jvm") version "2.3.21"
    kotlin("plugin.serialization") version "2.3.21"
    application
    jacoco
}

group = "com.solana.paykit"
version = "0.1.0"

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    // BouncyCastle gives a deterministic Ed25519 signer that takes the raw
    // 32 byte seed format Solana keypair files (and the MPP interop
    // harness) ship in. The JDK Ed25519 provider does not expose that
    // wire-level seed import path on every JVM.
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")
    // multimult is the Base58 codec maintained by Solana Mobile and used
    // by web3-solana and mobile-wallet-adapter-clientlib. Pulling it in
    // lets the SDK share the exact same Bitcoin-alphabet Base58
    // implementation as the rest of the Solana Mobile Kotlin stack
    // instead of carrying a hand-rolled BigInteger-based codec.
    implementation("io.github.funkatronics:multimult-jvm:0.2.3")
    // web3-solana is the Solana Mobile Kotlin transaction/instruction
    // library (production-used). The x402 exact client builds its
    // instructions through web3-solana's TransactionInstruction / AccountMeta
    // / SolanaPublicKey / TokenProgram.transferChecked so the SPL transfer
    // layout comes from a maintained library instead of being hand-rolled.
    // What it does NOT provide (and so stays hand-rolled in paycore): v0
    // VersionedMessage *compilation* (web3-solana's Message.Builder only
    // produces a LegacyMessage; VersionedMessage is a bare data class with no
    // try_compile path), the ComputeBudget program, and a synchronous ATA
    // derivation (only a suspend `find`). See Payment.kt for the bridge.
    implementation("com.solanamobile:web3-solana:0.3.1")
    // OkHttp is the canonical Kotlin/JVM HTTP client. Used by MppHttpClient
    // for 402-triggered credential build and retry.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation(kotlin("test"))
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}

// The cross-SDK conformance runner is a CLI entry point driven by the harness
// (harness/test/conformance.test.ts) over stdin/stdout, not by the SDK's own
// callers. `installDist` builds a start script once so the harness can invoke
// plain `java` per vector instead of paying gradle startup on every spawn.
application {
    mainClass.set("com.solana.paykit.conformance.ConformanceRunnerKt")
    applicationName = "conformance-runner"
}

tasks.test {
    useJUnitPlatform()
    finalizedBy(tasks.jacocoTestReport)
}

tasks.jacocoTestReport {
    dependsOn(tasks.test)
    reports {
        xml.required = true
        html.required = true
    }
}

// The conformance runner is exercised by the harness conformance suite over a
// spawned process, not by the Kotlin unit tests, so exclude it from the SDK's
// own line-coverage gate rather than letting an un-unit-tested CLI entry point
// drag the published library coverage below the threshold.
private val conformanceCoverageExclusions = listOf("com/solana/paykit/conformance/**")

tasks.jacocoTestReport {
    classDirectories.setFrom(
        files(classDirectories.files.map { dir ->
            fileTree(dir) { exclude(conformanceCoverageExclusions) }
        }),
    )
}

tasks.jacocoTestCoverageVerification {
    dependsOn(tasks.jacocoTestReport)
    classDirectories.setFrom(
        files(classDirectories.files.map { dir ->
            fileTree(dir) { exclude(conformanceCoverageExclusions) }
        }),
    )
    violationRules {
        rule {
            limit {
                counter = "LINE"
                minimum = "0.90".toBigDecimal()
            }
        }
    }
}

tasks.check {
    dependsOn(tasks.jacocoTestCoverageVerification)
}
