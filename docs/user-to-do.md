# todo issues for user

- [x] continue fixing preview: docs/processed-preview-stretch-bug-analysis.md
- [x] how is onconfigureFailed handled by our code?
- [x] explore how parameters are passed into the library for color calibration. is it good design?
- [x] research black balance. same as black levels?
- [x] what is data inside CamCapabilities used for?

- [ ] 
- [ ] select resolution  
- [ ] flutter hot restart camera goes crazy  
- [ ] port the awb patch manual calculation from other app
- [ ] set reasonable limits to contrast/brightness/etc. 
  Check against common editing apps if output is as expected
- [ ] finish up video recording. it should read from the processed frames. 
  add a button for it
- [ ] add a button for capture image and test it. capture image should have 
  the post-processing applied to it.
- [ ] /Users/shrek/.claude/plans/witty-cuddling-porcupine.md - Revised Camera Plugin Logging (10 tasks)
- [ ] Processing params don't persist. Slider values reset every app launch. SharedPreferences could persist them easily.
- [ ] Error handling with Result objects - https://docs.flutter.dev/app-architecture/design-patterns/result
- [ ] good dart design: https://dart.dev/effective-dart/design  , usage of libraries and such: https://dart.dev/effective-dart/usage , 
- [ ] App lifecycle (background/foreground) destroying the surface without proper recovery
- [ ] detect if GPU pipeline in a broken state, auto close and restart. 
- [ ]   


### Current coding session

- [ ] select resolution




------------------------------------------------------------------------------
  
  #### Error on app state change
  docs/diagnostic-logging-plan.md
  Most likely root cause: Hot restart orphaning the native session
  
    When flutter run does a hot restart:
    1. Dart state is wiped — CambrianCamera instances are lost
    2. Native plugin state (CambrianCameraPlugin.sessions) survives — the old CameraController +
    GpuPipeline keep running
    3. Dart calls CambrianCamera.open() again, creating a new native session
    4. But the old session still holds the camera device
    5. The new session either fails to open (camera in use) or opens a second session with stale
    surfaces
    6. No close() was called on the old session — it's leaked
  
    The _FlutterApiDispatcher routes callbacks by handle, so the old session's callbacks go to
    _instances[oldHandle] which no longer exists in Dart (wiped by hot restart). State events are
     silently dropped.
     
     the fix is in CambrianCameraPlugin — it needs to clean up stale
       sessions on engine re-initialization, or CameraController needs to handle the case where Dart
        reconnects to an existing native session.\
      
      
We suspect that: The Camera2 capture session was invalidated (possibly by hot restart, background/foreground,
  or another app seizing the camera), but no error was propagated to Dart. The GpuPipeline's
  onFrameAvailable stopped firing because Camera2 stopped delivering frames. The preview
  surfaces show stale/zeroed content. The shader applies contrast+saturation to zeros → deep
  blue.
        
#### error on app lifecycle (background)
docs/diagnostic-logging-plan.md
App lifecycle (background/foreground)

  There's a gap in CameraController.kt:265-284. When the app goes to background:
  - onSurfaceCleanup calls nativeSetPreviewWindow(ptr, null) on the ImagePipeline (CPU path)
  - But the GpuRenderer's EGL window surface is baked in at construction — there's no
  equivalent setPreviewWindow for the GPU path
  - When the app returns, onSurfaceAvailable restores the ImagePipeline surface but NOT the
  GpuRenderer's

  This would cause the preview to go black after a background/foreground cycle, though Camera2
  frames would still flow to the SurfaceTexture (just not to the preview surface).
  
  
  ### additional logging
  
  `docs/diagnostic-logging-plan.md`
  1. Frame heartbeat in GpuPipeline.onFrameAvailable — log every 100th frame so we can see
    if/when frames stop arriving. Right now there's zero logging in this critical path.
    2. Surface lifecycle events — onSurfaceAvailable / onSurfaceCleanup in CameraController.init
    have no logging. These are the most likely trigger for this bug.
    3. Session state on the Dart side — log when toneMappedTexture async generator yields vs
    stops.
  

  #### Here's how BLACK_LEVEL_LOCK works and when to use it:
  
    How It Works
  
    Set CaptureRequest.BLACK_LEVEL_LOCK to true on your repeating request. The camera HAL freezes
     its internal black level compensation at whatever values it currently has.
  
    builder.set(CaptureRequest.BLACK_LEVEL_LOCK, true)
  
    Critical Behavior: The HAL Can Override You
  
    Even with lock ON, the camera will temporarily unlock if you change settings that force a
    black level recalibration. From the docs:
    
    Frame 4 shows the HAL overriding your lock because the exposure change required a black level
       recalibration. Pixels on that frame may not be consistent with the others.
    
      When to Lock (for your use case)
    
      For uniform images during application logic:
    
      1. Stabilize all other capture parameters first — exposure, ISO, focus, white balance. Any
      change to these (especially sensitivity/exposure) can force a black level reset.
      2. Then lock black level — once the other settings are settled.
      3. Verify the lock in CaptureResult — check CaptureResult.BLACK_LEVEL_LOCK on each result
      frame. Only treat frames as uniform when the result confirms true.
    
      Where to add it in your code
    
      In your buildCaptureRequest at CameraController.kt:1036, it would go alongside the other ISP
      settings. The natural approach: always lock black level when manual exposure/ISO are in use
      (since you're already controlling those values and they won't drift):
    
      // Lock black level when all ISP parameters are stable
      if (wantsManualAe) {
          set(CaptureRequest.BLACK_LEVEL_LOCK, true)
      }
    
      Or expose it as its own flag in CamSettings if you want explicit control from Flutter.
    
      Verification: Read It Back
    
      On each CaptureResult, check:
      - CaptureResult.BLACK_LEVEL_LOCK — was it actually locked this frame?
      - CaptureResult.SENSOR_DYNAMIC_BLACK_LEVEL — the actual float[4] offsets used
    
      If BLACK_LEVEL_LOCK comes back false on a frame where you requested true, that frame had a
      black level reset and may not be pixel-consistent with its neighbors.
    
      Requirements
    
      - FULL hardware level — guaranteed present on FULL devices. May be null on LIMITED/LEGACY.
      - Check CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL before relying on it.
