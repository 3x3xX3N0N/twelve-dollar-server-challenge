import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("jvm") version "2.4.21"
}

repositories { mavenCentral() }

// No dependencies besides the Kotlin stdlib: SQLite is compiled by build.sh and called through FFM.

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_21)
        freeCompilerArgs.add("-Xno-param-assertions")
        freeCompilerArgs.add("-Xno-call-assertions")
        freeCompilerArgs.add("-Xno-receiver-assertions")
    }
}
java { targetCompatibility = JavaVersion.VERSION_21 }

// build/lib/*.jar = app + runtime deps; start.sh runs `java -cp 'build/lib/*'`. Sync drops stale jars.
val dist by tasks.registering(Sync::class) {
    from(tasks.jar)
    from(configurations.runtimeClasspath)
    into(layout.buildDirectory.dir("lib"))
}
tasks.build { dependsOn(dist) }
