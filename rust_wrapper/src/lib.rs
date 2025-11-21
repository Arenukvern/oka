use std::ffi::CString;
use std::os::raw::{c_char, c_void};

use jni::objects::{JClass, JObject, JString, JValue};
use jni::sys::{jint, JNI_VERSION_1_6};
use jni::{JNIEnv, JavaVM};
use ndk::native_activity::NativeActivity;
use ndk::native_window::NativeWindow;
use android_logger::Config;
use log::{info, error};

// Flutter engine declarations
// These would be linked from flutter engine static library
extern "C" {
    fn FlutterEngineRun(
        version: usize,
        args: *const FlutterEngineArgs,
        callbacks: *const FlutterEngineCallbacks,
        user_data: *mut c_void,
    ) -> *mut FlutterEngine;
    fn FlutterEngineShutdown(engine: *mut FlutterEngine) -> i32;
    fn FlutterEngineSendWindowMetricsEvent(
        engine: *mut FlutterEngine,
        event: *const FlutterWindowMetricsEvent,
    ) -> i32;
}

#[repr(C)]
struct FlutterEngineArgs {
    struct_size: usize,
    vm_snapshot_data: *const u8,
    vm_snapshot_instructions: *const u8,
    isolate_snapshot_data: *const u8,
    isolate_snapshot_instructions: *const u8,
    root_isolate_create_callback: Option<extern "C" fn(*mut c_void)>,
    root_isolate_create_callback_user_data: *mut c_void,
    initial_route: *const c_char,
    assets_path: *const c_char,
    packages_path: *const c_char,
    icu_data_path: *const c_char,
    command_line_args: *const *const c_char,
    command_line_args_count: i32,
}

#[repr(C)]
struct FlutterEngineCallbacks {
    struct_size: usize,
    platform_message_callback: Option<extern "C" fn(*const FlutterPlatformMessage, *mut c_void)>,
    root_isolate_create_callback: Option<extern "C" fn(*mut c_void)>,
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

type FlutterEngine = c_void;

struct FlutterApp {
    engine: Option<*mut FlutterEngine>,
    activity: NativeActivity,
    window: Option<NativeWindow>,
}

impl FlutterApp {
    fn new(activity: NativeActivity) -> Self {
        android_logger::init_once(Config::default().with_min_level(log::Level::Info));

        info!("Flutter wrapper initialized");

        Self {
            engine: None,
            activity,
            window: None,
        }
    }

    fn start_flutter_engine(&mut self) {
        info!("Starting Flutter engine...");

        // These paths will be set by the build system
        let assets_path = CString::new("flutter_assets").unwrap();
        let icu_data_path = CString::new("flutter_assets/icudtl.dat").unwrap();

        let args = FlutterEngineArgs {
            struct_size: std::mem::size_of::<FlutterEngineArgs>(),
            vm_snapshot_data: std::ptr::null(),
            vm_snapshot_instructions: std::ptr::null(),
            isolate_snapshot_data: std::ptr::null(),
            isolate_snapshot_instructions: std::ptr::null(),
            root_isolate_create_callback: None,
            root_isolate_create_callback_user_data: std::ptr::null_mut(),
            initial_route: std::ptr::null(),
            assets_path: assets_path.as_ptr(),
            packages_path: std::ptr::null(),
            icu_data_path: icu_data_path.as_ptr(),
            command_line_args: std::ptr::null(),
            command_line_args_count: 0,
        };

        let callbacks = FlutterEngineCallbacks {
            struct_size: std::mem::size_of::<FlutterEngineCallbacks>(),
            platform_message_callback: Some(platform_message_callback),
            root_isolate_create_callback: Some(root_isolate_create_callback),
            user_data: self as *mut Self as *mut c_void,
        };

        unsafe {
            let engine = FlutterEngineRun(1, &args, &callbacks, self as *mut Self as *mut c_void);
            if engine.is_null() {
                error!("Failed to start Flutter engine");
                return;
            }
            self.engine = Some(engine);
            info!("Flutter engine started successfully");
        }
    }

    fn shutdown_flutter_engine(&mut self) {
        if let Some(engine) = self.engine {
            unsafe {
                FlutterEngineShutdown(engine);
            }
            self.engine = None;
            info!("Flutter engine shut down");
        }
    }

    fn on_window_created(&mut self, window: NativeWindow) {
        self.window = Some(window);
        info!("Window created");

        // Notify Flutter of window metrics
        if let Some(engine) = self.engine {
            // Get window size from Android
            let metrics = FlutterWindowMetricsEvent {
                struct_size: std::mem::size_of::<FlutterWindowMetricsEvent>(),
                width: 1080,  // These should come from actual window
                height: 1920,
                pixel_ratio: 3.0,
            };

            unsafe {
                FlutterEngineSendWindowMetricsEvent(engine, &metrics);
            }
        }
    }

    fn on_window_destroyed(&mut self) {
        self.window = None;
        info!("Window destroyed");
    }
}

extern "C" fn platform_message_callback(
    message: *const FlutterPlatformMessage,
    user_data: *mut c_void,
) {
    // Handle platform messages from Flutter
    info!("Received platform message");
}

extern "C" fn root_isolate_create_callback(user_data: *mut c_void) {
    info!("Root isolate created");
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onCreate(
    activity: *mut ndk_sys::ANativeActivity,
    saved_state: *mut c_void,
    saved_state_size: usize,
) {
    info!("NativeActivity onCreate");

    let native_activity = unsafe { NativeActivity::from_ptr(activity) };
    let mut app = Box::new(FlutterApp::new(native_activity));

    // Store our app in the activity's instance field
    unsafe {
        (*activity).instance = Box::into_raw(app) as *mut c_void;
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onDestroy(activity: *mut ndk_sys::ANativeActivity) {
    info!("NativeActivity onDestroy");

    let app_ptr = unsafe { (*activity).instance as *mut FlutterApp };
    if !app_ptr.is_null() {
        let app = unsafe { Box::from_raw(app_ptr) };
        app.shutdown_flutter_engine();
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onStart(activity: *mut ndk_sys::ANativeActivity) {
    info!("NativeActivity onStart");

    let app_ptr = unsafe { (*activity).instance as *mut FlutterApp };
    if !app_ptr.is_null() {
        let app = unsafe { &mut *app_ptr };
        app.start_flutter_engine();
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onStop(activity: *mut ndk_sys::ANativeActivity) {
    info!("NativeActivity onStop");

    let app_ptr = unsafe { (*activity).instance as *mut FlutterApp };
    if !app_ptr.is_null() {
        let app = unsafe { &mut *app_ptr };
        app.shutdown_flutter_engine();
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onWindowFocusChanged(
    activity: *mut ndk_sys::ANativeActivity,
    has_focus: i32,
) {
    info!("NativeActivity onWindowFocusChanged: {}", has_focus);
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onNativeWindowCreated(
    activity: *mut ndk_sys::ANativeActivity,
    window: *mut ndk_sys::ANativeWindow,
) {
    info!("NativeActivity onNativeWindowCreated");

    let app_ptr = unsafe { (*activity).instance as *mut FlutterApp };
    if !app_ptr.is_null() {
        let app = unsafe { &mut *app_ptr };
        let native_window = unsafe { NativeWindow::from_ptr(window) };
        app.on_window_created(native_window);
    }
}

#[no_mangle]
pub extern "C" fn ANativeActivity_onNativeWindowDestroyed(
    activity: *mut ndk_sys::ANativeActivity,
    window: *mut ndk_sys::ANativeWindow,
) {
    info!("NativeActivity onNativeWindowDestroyed");

    let app_ptr = unsafe { (*activity).instance as *mut FlutterApp };
    if !app_ptr.is_null() {
        let app = unsafe { &mut *app_ptr };
        app.on_window_destroyed();
    }
}
