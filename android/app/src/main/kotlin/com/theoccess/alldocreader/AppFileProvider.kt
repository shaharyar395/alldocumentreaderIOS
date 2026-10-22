package com.theoccess.alldocreader

import androidx.core.content.FileProvider

/**
 * The app's own FileProvider (authority "<applicationId>.fileprovider", paths in
 * res/xml/file_paths.xml) for "Open with another app" and "Save to Drive". A subclass, so it never
 * clashes with the FileProviders that plugins declare in the merged manifest.
 */
class AppFileProvider : FileProvider()
