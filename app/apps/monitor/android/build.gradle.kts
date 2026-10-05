allprojects {
    repositories {
        google()
        mavenCentral()
        // The unchanged USB driver 6.1.0 is published on JitPack.
        maven {
            url = uri("https://jitpack.io")
            content { includeGroup("com.github.felHR85") }
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
