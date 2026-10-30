plugins {
    id("com.android.library") version "8.7.3"
    kotlin("android") version "2.0.21"
    id("maven-publish")
}

group = "com.github.msgera.push-sdks"
version = "1.1.0"

android {
    namespace = "io.msgera.push"
    compileSdk = 35

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

dependencies {
    // The customer's app applies the Google services plugin and ships
    // google-services.json. This library only reads the FCM token.
    implementation("com.google.firebase:firebase-messaging:24.1.1")
    implementation("androidx.core:core-ktx:1.15.0")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "com.github.msgera.push-sdks"
                artifactId = "android"
                version = "1.1.0"
            }
        }
    }
}
