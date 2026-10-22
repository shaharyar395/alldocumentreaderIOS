allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
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
    // The ML Kit plugin depends on the bundled recognizer, which packs a ~11 MB
    // native library and model files into every APK. Play services hosts the same
    // recognizer and downloads the model on first use.
    configurations.configureEach {
        resolutionStrategy.dependencySubstitution {
            substitute(module("com.google.mlkit:text-recognition"))
                .using(module("com.google.android.gms:play-services-mlkit-text-recognition:19.0.1"))
            substitute(module("com.google.mlkit:text-recognition-chinese"))
                .using(module("com.google.android.gms:play-services-mlkit-text-recognition-chinese:16.0.1"))
            substitute(module("com.google.mlkit:text-recognition-devanagari"))
                .using(module("com.google.android.gms:play-services-mlkit-text-recognition-devanagari:16.0.1"))
            substitute(module("com.google.mlkit:text-recognition-japanese"))
                .using(module("com.google.android.gms:play-services-mlkit-text-recognition-japanese:16.0.1"))
            substitute(module("com.google.mlkit:text-recognition-korean"))
                .using(module("com.google.android.gms:play-services-mlkit-text-recognition-korean:16.0.1"))
        }
    }
}
subprojects {
    afterEvaluate {
        extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.apply {
            compileSdk = 36
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
