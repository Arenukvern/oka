use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::ptr;

use android_logger::Config;
use log::{debug, error, info, warn};
use ndk::native_activity::NativeActivity;
use ndk::native_window::NativeWindow;

// Flutter Engine API declarations
// These will be linked from the Flutter engine static library
#[link(name = "flutter_engine")]
extern "C" {
    fn FlutterEngineRun(
        version: usize,
        args: *const FlutterEngineArgs,
        callbacks: *const FlutterEngineCallbacks,
        user_data: *mut c_void,
    ) -> *mut FlutterEngine;

    fn FlutterEngineShutdown(engine: *mut FlutterEngine) -> FlutterEngineResult;

    fn FlutterEngineSendWindowMetricsEvent(
        engine: *mut FlutterEngine,
        event: *const FlutterWindowMetricsEvent,
    ) -> FlutterEngineResult;

    fn FlutterEngineSendPointerEvent(
        engine: *mut FlutterEngine,
        events: *const FlutterPointerEvent,
        count: usize,
    ) -> FlutterEngineResult;

    fn FlutterEngineSendPlatformMessage(
        engine: *mut FlutterEngine,
        message: *const FlutterPlatformMessage,
    ) -> FlutterEngineResult;

    fn FlutterEngineRunTask(engine: *mut FlutterEngine, task: *const c_void) -> FlutterEngineResult;
}

type FlutterEngine = c_void;
type FlutterEngineResult = c_int;

#[repr(C)]
#[derive(Debug)]
struct FlutterEngineArgs {
    struct_size: usize,
    vm_snapshot_data: *const u8,
    vm_snapshot_instructions: *const u8,
    isolate_snapshot_data: *const u8,
    isolate_snapshot_instructions: *const u8,
    root_isolate_create_callback: Option<extern "C" fn(user_data: *mut c_void)>,
    root_isolate_create_callback_user_data: *mut c_void,
    initial_route: *const c_char,
    assets_path: *const c_char,
    packages_path: *const c_char,
    icu_data_path: *const c_char,
    command_line_args: *const *const c_char,
    command_line_args_count: c_int,
}

#[repr(C)]
struct FlutterEngineCallbacks {
    struct_size: usize,
    platform_message_callback: Option<extern "C" fn(message: *const FlutterPlatformMessage, user_data: *mut c_void)>,
    root_isolate_create_callback: Option<extern "C" fn(user_data: *mut c_void)>,
    user_data: *mut c_void,
}

#[repr(C)]
struct FlutterPlatformMessage {
    struct_size: usize,
    channel: *const c_char,
    message: *const u8,
    message_size: usize,
    response_handle: *const FlutterPlatformMessageResponseHandle,
}

#[repr(C)]
struct FlutterPlatformMessageResponseHandle;

#[repr(C)]
struct FlutterWindowMetricsEvent {
    struct_size: usize,
    width: usize,
    height: usize,
    pixel_ratio: f64,
}

#[repr(C)]
struct FlutterPointerEvent {
    struct_size: usize,
    timestamp: usize,
    phase: FlutterPointerPhase,
    device_kind: FlutterPointerDeviceKind,
    signal_kind: FlutterPointerSignalKind,
    device: i32,
    pointer: usize,
    x: f64,
    y: f64,
    scroll_delta_x: f64,
    scroll_delta_y: f64,
}

#[repr(C)]
#[derive(Debug)]
enum FlutterPointerPhase {
    Cancel,
    Up,
    Down,
    Move,
    Add,
    Remove,
    Hover,
}

#[repr(C)]
enum FlutterPointerDeviceKind {
    Mouse,
    Touch,
    Stylus,
    Trackpad,
}

#[repr(C)]
enum FlutterPointerSignalKind {
    None,
    Scroll,
}

struct FlutterApp {
    engine: Option<*mut FlutterEngine>,
    activity: NativeActivity,
    window: Option<NativeWindow>,
    assets_path: String,
    icu_data_path: String,
}

impl FlutterApp {
    fn new(activity: NativeActivity) -> Self {
        android_logger::init_once(
            Config::default()
                .with_min_level(log::Level::Debug)
                .with_tag("FlutterWrapper"),
        );

        info!("Initializing Flutter wrapper");

        // Get asset paths from APK structure
        // cargo-apk places assets in the root of the APK
        let assets_path = "flutter_assets".to_string();
        let icu_data_path = "flutter_assets/icudtl.dat".to_string();

        Self {
            engine: None,
            activity,
            window: None,
            assets_path,
            icu_data_path,
        }
    }

    fn start_flutter_engine(&mut self) -> Result<(), String> {
        info!("Starting Flutter engine with assets at: {}", self.assets_path);

        let assets_path_c = CString::new(self.assets_path.clone())
            .map_err(|e| format!("Invalid assets path: {}", e))?;
        let icu_data_path_c = CString::new(self.icu_data_path.clone())
            .map_err(|e| format!("Invalid ICU data path: {}", e))?;

        let args = FlutterEngineArgs {
            struct_size: std::mem::size_of::<FlutterEngineArgs>(),
            vm_snapshot_data: ptr::null(),
            vm_snapshot_instructions: ptr::null(),
            isolate_snapshot_data: ptr::null(),
            isolate_snapshot_instructions: ptr::null(),
            root_isolate_create_callback: Some(root_isolate_create_callback),
            root_isolate_create_callback_user_data: self as *mut Self as *mut c_void,
            initial_route: ptr::null(),
            assets_path: assets_path_c.as_ptr(),
            packages_path: ptr::null(),
            icu_data_path: icu_data_path_c.as_ptr(),
            command_line_args: ptr::null(),
            command_line_args_count: 0,
        };

        let callbacks = FlutterEngineCallbacks {
            struct_size: std::mem::size_of::<FlutterEngineCallbacks>(),
            platform_message_callback: Some(platform_message_callback),
            root_isolate_create_callback: Some(root_isolate_create_callback),
            user_data: self as *mut Self as *mut c_void,
        };

        let engine = unsafe {
            FlutterEngineRun(
                1, // FLUTTER_ENGINE_VERSION
                &args,
                &callbacks,
                self as *mut Self as *mut c_void,
            )
        };

        if engine.is_null() {
            error!("Failed to start Flutter engine");
            return Err("Flutter engine initialization failed".to_string());
        }

        self.engine = Some(engine);
        info!("Flutter engine started successfully");
        Ok(())
    }

    fn shutdown_flutter_engine(&mut self) {
        if let Some(engine) = self.engine.take() {
            unsafe {
                let result = FlutterEngineShutdown(engine);
                if result != 0 {
                    error!("Flutter engine shutdown failed with code: {}", result);
                } else {
                    info!("Flutter engine shut down successfully");
                }
            }
        }
    }

    fn notify_window_metrics(&self, width: usize, height: usize, pixel_ratio: f64) {
        if let Some(engine) = self.engine {
            let metrics = FlutterWindowMetricsEvent {
                struct_size: std::mem::size_of::<FlutterWindowMetricsEvent>(),
                width,
                height,
                pixel_ratio,
            };

            unsafe {
                let result = FlutterEngineSendWindowMetricsEvent(engine, &metrics);
                if result != 0 {
                    error!("Failed to send window metrics event: {}", result);
                } else {
                    debug!("Window metrics updated: {}x{} @ {}", width, height, pixel_ratio);
                }
            }
        }
    }

    fn on_window_created(&mut self, window: NativeWindow) {
        self.window = Some(window);
        info!("Native window created");

        // Get actual window dimensions
        // For now, use default values - in production you'd query the window
        self.notify_window_metrics(1080, 1920, 3.0);
    }

    fn on_window_destroyed(&mut self) {
        self.window = None;
        info!("Native window destroyed");
    }

    fn run_engine_tasks(&self) {
        if let Some(engine) = self.engine {
            unsafe {
                // Run any pending tasks in the engine
                let _ = FlutterEngineRunTask(engine, ptr::null());
            }
        }
    }
}

impl Drop for FlutterApp {
    fn drop(&mut self) {
        self.shutdown_flutter_engine();
    }
}

extern "C" fn platform_message_callback(
    message: *const FlutterPlatformMessage,
    user_data: *mut c_void,
) {
    if message.is_null() {
        return;
    }

    unsafe {
        let channel = CStr::from_ptr((*message).channel).to_string_lossy();
        debug!("Received platform message on channel: {}", channel);
    }
}

extern "C" fn root_isolate_create_callback(user_data: *mut c_void) {
    info!("Flutter root isolate created");
}

// Native Activity lifecycle callbacks

static mut APP_INSTANCE: Option<Box<FlutterApp>> = None;

#[no_mangle]
pub extern "C" fn ANativeActivity_onCreate(
    activity: *mut ndk_sys::ANativeActivity,
    saved_state: *mut c_void,
    saved_state_size: usize,
) {
    info!("ANativeActivity_onCreate");

    unsafe {
        if APP_INSTANCE.is_some() {
            warn!("App instance already exists, replacing");
        }

        let native_activity = NativeActivity::from_ptr(activity);
        let app = Box::new(FlutterApp::new(native_activity));
        (*activity).instance = app.as_ref() as *const FlutterApp as *mut c_void;
        APP_INSTANCE = Some(app);
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onDestroy(activity: *mut ndk_sys::ANativeActivity) {
    info!("ANativeActivity_onDestroy");

    unsafe {
        if let Some(app) = APP_INSTANCE.take() {
            drop(app);
        }
        (*activity).instance = ptr::null_mut();
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onStart(activity: *mut ndk_sys::ANativeActivity) {
    info!("ANativeActivity_onStart");

    unsafe {
        if let Some(ref mut app) = APP_INSTANCE {
            if let Err(e) = app.start_flutter_engine() {
                error!("Failed to start Flutter engine: {}", e);
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onResume(activity: *mut ndk_sys::ANativeActivity) {
    info!("ANativeActivity_onResume");

    unsafe {
        if let Some(ref app) = APP_INSTANCE {
            app.run_engine_tasks();
        }
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onPause(activity: *mut ndk_sys::ANativeActivity) {
    info!("ANativeActivity_onPause");

    unsafe {
        if let Some(ref app) = APP_INSTANCE {
            app.run_engine_tasks();
        }
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onStop(activity: *mut ndk_sys::ANativeActivity) {
    info!("ANativeActivity_onStop");

    unsafe {
        if let Some(ref mut app) = APP_INSTANCE {
            app.shutdown_flutter_engine();
        }
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onWindowFocusChanged(
    activity: *mut ndk_sys::ANativeActivity,
    has_focus: c_int,
) {
    debug!("ANativeActivity_onWindowFocusChanged: focus={}", has_focus);

    unsafe {
        if let Some(ref app) = APP_INSTANCE {
            app.run_engine_tasks();
        }
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onNativeWindowCreated(
    activity: *mut ndk_sys::ANativeActivity,
    window: *mut ndk_sys::ANativeWindow,
) {
    info!("ANativeActivity_onNativeWindowCreated");

    unsafe {
        if let Some(ref mut app) = APP_INSTANCE {
            let native_window = NativeWindow::from_ptr(window);
            app.on_window_created(native_window);
        }
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onNativeWindowDestroyed(
    activity: *mut ndk_sys::ANativeActivity,
    window: *mut ndk_sys::ANativeWindow,
) {
    info!("ANativeActivity_onNativeWindowDestroyed");

    unsafe {
        if let Some(ref mut app) = APP_INSTANCE {
            app.on_window_destroyed();
        }
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onInputQueueCreated(
    activity: *mut ndk_sys::ANativeActivity,
    queue: *mut ndk_sys::AInputQueue,
) {
    debug!("ANativeActivity_onInputQueueCreated");
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onInputQueueDestroyed(
    activity: *mut ndk_sys::ANativeActivity,
    queue: *mut ndk_sys::AInputQueue,
) {
    debug!("ANativeActivity_onInputQueueDestroyed");
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onConfigurationChanged(activity: *mut ndk_sys::ANativeActivity) {
    debug!("ANativeActivity_onConfigurationChanged");
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onLowMemory(activity: *mut ndk_sys::ANativeActivity) {
    warn!("ANativeActivity_onLowMemory");

    unsafe {
        if let Some(ref app) = APP_INSTANCE {
            app.run_engine_tasks();
        }
    }
}
