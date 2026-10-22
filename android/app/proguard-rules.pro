# Room builds WorkDatabase_Impl by reflection. R8 full mode drops that constructor
# and ads crash at startup with "Failed to create an instance of WorkDatabase".
-keep class androidx.work.impl.WorkDatabase_Impl { <init>(); }
-keep class * extends androidx.room.RoomDatabase { *; }
-keep class androidx.work.** { *; }
-keep class androidx.startup.** { *; }

# pdfbox-android (assemblePdf): optional JPEG 2000 decoder is not bundled
-dontwarn com.gemalto.jp2.**
-keep class com.tom_roush.pdfbox.** { *; }
-keep class com.tom_roush.fontbox.** { *; }
