group = "dev.bugcapsule.bug_capsule_native"
version = "0.1.0-beta.1"

// The BugCapsule Android SDK release with dev.bugcapsule.android.embedding.CrashBridge.
val bugCapsuleAndroidVersion = "0.4.1-beta.5"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "dev.bugcapsule.bug_capsule_native"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        // The BugCapsule Android SDK's minimum.
        minSdk = 23
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("io.github.bugcapsule:bugcapsule-android:$bugCapsuleAndroidVersion")
    // NDK signal handler: native crashes of the app, the engine and plugins.
    implementation("io.github.bugcapsule:bugcapsule-ndk:$bugCapsuleAndroidVersion")
}
