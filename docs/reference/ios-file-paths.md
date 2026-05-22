# iOS File Paths — CambrianCamera

## What `result.filePath` contains on iOS

All capture APIs (`captureImage`, `captureNaturalPicture`, `startRecording`, `stopRecording`)
return a bare POSIX path such as:

```
/var/mobile/Containers/Data/Application/<UUID>/Documents/IMG_2026-05-22T12-23-29Z.jpg
```

The full path including the UUID is the file's actual location. There is no `file://` scheme
prefix. `dart:io`'s `File` API works on it directly.

## App sandbox layout

`NSHomeDirectory()` — e.g. `/var/mobile/Containers/Data/Application/<UUID>/` — is the sandbox
root. Captures land in `Documents/` by default.

```
<sandbox root>/
├── Documents/          ← where captures are saved; visible in Files.app
├── Library/
│   ├── Caches/         ← OS may purge when storage is low
│   ├── Preferences/
│   └── Application Support/
└── tmp/                ← purged on app relaunch
```

The UUID is the app container identifier — stable across launches, changes only on
delete-and-reinstall. Never hardcode it; always derive paths via `URL.documentsDirectory`,
`FileManager.default.temporaryDirectory`, etc.

## Files.app visibility

`UIFileSharingEnabled = YES` and `LSSupportsOpeningDocumentsInPlace = YES` in `Info.plist`
expose the `Documents/` directory in Files.app under "On My iPhone / iPad" and over
USB/Finder. Only `Documents/` is exposed — `Library/` and `tmp/` are not visible.

## Moving, renaming, copying files from Dart

Because the path is a plain POSIX path inside the sandbox, `dart:io` file operations work
without any platform channel calls:

```dart
final result = await camera.captureImage();
final src = File(result.filePath!);

// Rename / move — atomic, zero-copy when staying on the same volume
final moved = await src.rename('${src.parent.path}/new-name.jpg');

// Copy
final copy = await src.copy('/other/sandbox/subdir/copy.jpg');

// Delete
await src.delete();
```

The destination must remain inside the app sandbox. Paths outside the sandbox (e.g.
`/tmp/...` at the system root, another app's container) will throw `FileSystemException`.

## Contrast with Android

On Android, `captureImage` writes via MediaStore into shared external storage
(`/storage/emulated/0/Pictures/CambrianCamera/`) and the file appears in the system
Photos gallery. On iOS the file lives only in the app sandbox; it never appears in Photos
unless `saveToLibrary: true` is passed.

## `/var` vs `/private/var`

`/var` on iOS is a symlink to `/private/var`. `FileManager.default.temporaryDirectory`
resolves through the symlink and returns the `/private/var/...` form; `NSHomeDirectory()`
returns the `/var/...` form. Both point to the same physical location. The sandbox escape
check in `PhotosLibraryClient.resolve` accepts both forms — see
`PhotosLibraryClientTests.sandboxTmpDirectorySymlinkAccepted`.
