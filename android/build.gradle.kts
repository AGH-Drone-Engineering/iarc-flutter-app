allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// objectbox_flutter_libs 4.3.1 hardcodes compileSdk 31, but its AndroidX transitive
// dependencies require 34+. AGP 8.11+ enforces this via checkAarMetadata, so raise any
// plugin still compiling below the app's level. Raising compileSdk is backward compatible
// and affects neither minSdk nor targetSdk.
subprojects {
    val raiseCompileSdk = {
        val androidExtension = extensions.findByName("android")
        if (androidExtension is com.android.build.gradle.BaseExtension) {
            val currentSdk =
                androidExtension.compileSdkVersion
                    ?.substringAfter("android-")
                    ?.toIntOrNull()
            if (currentSdk != null && currentSdk < 36) {
                androidExtension.compileSdkVersion(36)
            }
        }
    }
    if (state.executed) raiseCompileSdk() else afterEvaluate { raiseCompileSdk() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}