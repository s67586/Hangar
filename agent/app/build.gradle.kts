plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.hangar.agent"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.hangar.agent"
        // 26：前景服務與通知頻道的分水嶺。比這更舊的機器不在這個專案的守備範圍。
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
        // 協定版本。改了要同時改 ROADMAP 的「M3 協定」與 tests/test_agent_protocol.sh
        buildConfigField("int", "PROTOCOL_SCHEMA", "1")
    }

    buildFeatures { buildConfig = true }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

// 刻意沒有任何相依套件（連 AndroidX 都沒有）。理由跟 hangar 是一支無相依 bash
// script、hub 只用 Python 標準函式庫一樣：這支 app 要做的事框架本身都有。
dependencies { }
