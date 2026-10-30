plugins {
    id("com.android.library") version "8.7.3"
    kotlin("android") version "2.0.21"
    id("maven-publish")
}

group = "com.github.msgera.push-sdks"
version = "1.1.0"

android {
    namespace = "io.msgera.push.huawei"
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
    implementation("com.huawei.hms:push:6.13.0.300")
    implementation("androidx.core:core-ktx:1.15.0")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "com.github.msgera.push-sdks"
                artifactId = "android-huawei"
                version = "1.1.0"
            }
        }
    }
}
