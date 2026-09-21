import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key, when there is one.
//
// `android/key.properties` is the Flutter convention and is in
// .gitignore twice over, here and at the repository root -- a keystore
// in a public repository is the one mistake in Android signing that
// cannot be undone, because Play ties the app to the key forever and a
// leaked upload key has to be reset by Google by hand.
//
// `.github/workflows/android-release.yml` writes this file from
// secrets for the length of one job and deletes it afterwards. On a
// developer's machine it is absent, which is the case the `else`
// branch below is for.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "my.iakauntan.iakauntan"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "my.iakauntan.iakauntan"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Only declared when the keystore is actually there. Declaring
        // it unconditionally and letting Gradle resolve a null path
        // fails much later, inside the signing task, with a message
        // about a file rather than about configuration.
        if (keyProperties.getProperty("storeFile") != null) {
            create("release") {
                storeFile = rootProject.file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The upload key where there is one, the debug key where
            // there is not.
            //
            // The fallback is deliberate and is NOT a way to ship: a
            // debug-signed bundle is refused by Play, and `flutter run
            // --release` on a developer's own handset has to keep
            // working without handing every developer the upload key.
            //
            // What makes the fallback safe is that it is never silent.
            // The release workflow always writes key.properties, and
            // then VERIFIES the signer on the built artifact before
            // uploading -- because the failure this guards is a
            // debug-signed bundle reaching Play's API and being
            // refused with a message about a certificate, twenty
            // minutes after the build everyone believed was signed.
            if (signingConfigs.findByName("release") != null) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                logger.lifecycle(
                    "android: no key.properties, so the release build is " +
                        "signed with the DEBUG key. Play will refuse it. " +
                        "See docs/android-release.md."
                )
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
