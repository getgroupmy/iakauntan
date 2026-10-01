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

// Firebase, when there is a project to point it at.
//
// `google-services.json` is not in this repository and must not be: it
// names a Firebase project, and a project named in a public repository
// is a project strangers can try to register devices against. The
// release workflow writes it from a secret for the length of one job,
// the same arrangement as `key.properties` above.
//
// So the ordinary case -- every CI build, every developer who has not
// been given the file -- has no Firebase configuration at all, and the
// plugin that generates the string resources from it is simply not
// applied. That is NOT a broken build:
//
//   * `firebase-messaging` below still compiles in, so the manifest
//     merge, the service declaration and every line of `Push.kt` are
//     built and checked by the `android` job on every push. The whole
//     point of that job is to answer "does the Android app build", and
//     a Firebase client that only compiles on release days would be
//     outside its reach.
//
//   * At run time there is then no default `FirebaseApp`, which
//     `Push.configured` detects and the settings card reports as "not
//     configured" -- rather than offering a switch that would register
//     a token nothing can ever send to.
//
// Applying it unconditionally is what the Firebase documentation says
// to do, and it would fail every build in this repository with
// `File google-services.json is missing`. Hence the `if`.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
} else {
    logger.lifecycle(
        "android: no google-services.json, so this build has no Firebase " +
            "project and push answers \"not configured\" on Android. " +
            "See docs/push-notifications.md."
    )
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

            // R8 needs telling about four ML Kit script recognizers
            // that are referenced by the text-recognition plugin and
            // are not dependencies here. Without this the release
            // build fails at `:app:minifyReleaseWithR8` — which no
            // debug build reaches, so it first appeared on the very
            // first attempt to publish. `proguard-rules.pro` carries
            // the reasoning and the gate that keeps it honest.
            //
            // Both files, not just ours: `proguardFiles` REPLACES the
            // list rather than adding to it, and dropping the default
            // would turn off the optimisations every Android release
            // is built with.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    // Push on Android, which has no transport but this one.
    //
    // A BOM rather than versions, because the Firebase libraries are
    // only tested against each other in sets and mixing two sets
    // produces a `NoSuchMethodError` at run time rather than anything
    // at build time.
    //
    // PINNED, and 33.7.0 rather than something newer, for the reason
    // every version in this repository is pinned: it is a version that
    // is known to exist. `dl.google.com` is not reachable from the
    // machine this was written on, so a guess at a newer one could not
    // be checked and would fail the Android build with a message about
    // a missing artifact. Raising it is a deliberate act with a build
    // in front of it.
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-messaging")

    // `NotificationCompat` and `NotificationManagerCompat`, which
    // `PushService` draws a call with. Already on the runtime classpath
    // through half the plugins in this tree; declared because a
    // transitive dependency is not a promise, and because the compile
    // classpath does not inherit it in any case.
    implementation("androidx.core:core-ktx:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
