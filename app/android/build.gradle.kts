allprojects {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://storage.googleapis.com/download.flutter.io")
        }
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Every plugin compiles against at least the SDK the app does.
//
// `flutter_plugin_android_lifecycle` requires anything depending on it
// to compile against API 36, and five plugins in this tree pin a lower
// one in their own `build.gradle`: file_picker and flutter_doc_scanner
// and passkeys_android and ua_client_hints at 34, audioplayers_android
// at 35. Gradle refuses the first one it reaches --
//
//     Execution failed for task ':file_picker:checkDebugAarMetadata'.
//     > Dependency ':flutter_plugin_android_lifecycle' requires
//       libraries and applications that depend on it to compile
//       against version 36 or later of the Android APIs.
//       :file_picker is currently compiled against android-34.
//
// -- and then stops, so finding them by pushing is one CI round trip
// per plugin. All five were found at once by reading their
// `build.gradle` files out of the pub cache.
//
// ## Why a floor and not five version bumps
//
// Because two of them have nowhere to go. `flutter_doc_scanner`'s
// latest release IS 0.0.21 and `ua_client_hints`'s IS 1.7.0 -- both
// already the newest published, both pinning 34. No set of version
// constraints fixes this.
//
// ## Why this is safe
//
// `compileSdk` decides which APIs the code may CALL. It is
// `targetSdk` that opts an app into new runtime behaviour, and that is
// untouched here -- so raising this changes what compiles, not what
// happens on a handset. It is the documented action in the message
// above.
//
// A FLOOR rather than an assignment: nothing is ever lowered. The
// three plugins that already name a version -- flutter_webrtc and the
// two ML Kit ones -- all say 36 exactly, so today this raises five and
// leaves those alone, and if one of them ever moves to 37 it keeps it.
//
// ## Why it is written with reflection
//
// So that it depends on no AGP type. `com.android.build.gradle.BaseExtension`
// is the usual way to write this and is deprecated in AGP 9, which is
// what `settings.gradle.kts` declares; `dl.google.com` is not reachable
// from the machine this was written on, so which classes AGP 9.1.0 still
// carries could not be checked. Going through the extension object by
// name needs nothing on the compile classpath.
//
// `single { }` rather than `firstOrNull { }` deliberately: if AGP ever
// renames `compileSdk`, this fails with a message naming the project
// rather than silently doing nothing and leaving the original
// `checkDebugAarMetadata` failure to be diagnosed a second time.
subprojects {
    afterEvaluate {
        val android = extensions.findByName("android") ?: return@afterEvaluate
        val floor = 36

        val getter = android.javaClass.methods.single {
            it.name == "getCompileSdk" && it.parameterCount == 0
        }
        val setter = android.javaClass.methods.single {
            it.name == "setCompileSdk" && it.parameterCount == 1 &&
                (it.parameterTypes[0] == Integer::class.java ||
                    it.parameterTypes[0] == Int::class.javaPrimitiveType)
        }

        val current = getter.invoke(android) as? Int
        if (current == null || current < floor) {
            setter.invoke(android, floor)
            logger.info(
                "compileSdk raised to $floor for ${project.name} " +
                    "(was ${current ?: "unset"})"
            )
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
