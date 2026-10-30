tasks.register("publishToMavenLocal") {
    dependsOn(":android:publishToMavenLocal", ":android-huawei:publishToMavenLocal")
}
