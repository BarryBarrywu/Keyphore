#[cfg(not(target_os = "macos"))]
use anyhow::bail;
use anyhow::{Context, Result};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PowerEvent {
    WillSleep,
    DidWake,
}

#[derive(Default)]
pub struct PowerGate {
    suspended: AtomicBool,
    generation: AtomicU64,
    hid_access: Mutex<()>,
}

impl PowerGate {
    pub fn begin_hid_access(&self) -> Option<HidAccess<'_>> {
        self.begin_hid_access_at(None)
    }

    pub fn begin_hid_access_for(&self, generation: u64) -> Option<HidAccess<'_>> {
        self.begin_hid_access_at(Some(generation))
    }

    fn begin_hid_access_at(&self, generation: Option<u64>) -> Option<HidAccess<'_>> {
        let guard = self.hid_access.lock().expect("HID access lock poisoned");
        if self.suspended.load(Ordering::Acquire)
            || generation.is_some_and(|expected| self.generation() != expected)
        {
            return None;
        }
        Some(HidAccess { _guard: guard })
    }

    pub fn handle(&self, event: PowerEvent) {
        let _guard = self.hid_access.lock().expect("HID access lock poisoned");
        if event == PowerEvent::DidWake {
            self.generation.fetch_add(1, Ordering::AcqRel);
        }
        self.suspended
            .store(matches!(event, PowerEvent::WillSleep), Ordering::Release);
    }

    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }
}

pub struct HidAccess<'a> {
    _guard: MutexGuard<'a, ()>,
}

pub struct SystemPowerMonitor {
    gate: Arc<PowerGate>,
}

impl SystemPowerMonitor {
    pub fn register() -> Result<Self> {
        let gate = Arc::new(PowerGate::default());
        register_system_power_notifications(Arc::clone(&gate))?;
        Ok(Self { gate })
    }

    pub fn gate(&self) -> &PowerGate {
        &self.gate
    }
}

#[cfg(target_os = "macos")]
fn register_system_power_notifications(gate: Arc<PowerGate>) -> Result<()> {
    use std::sync::mpsc;
    use std::thread;

    let (registered_tx, registered_rx) = mpsc::sync_channel(1);
    thread::Builder::new()
        .name("keyphore-system-power".into())
        .spawn(move || macos::run_power_notification_loop(gate, registered_tx))
        .context("failed to start system power monitor")?;
    registered_rx
        .recv()
        .context("system power monitor stopped during registration")?
}

#[cfg(not(target_os = "macos"))]
fn register_system_power_notifications(_gate: Arc<PowerGate>) -> Result<()> {
    bail!("system power monitoring requires macOS")
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{PowerEvent, PowerGate};
    use anyhow::{Result, anyhow};
    use std::ffi::c_void;
    use std::ptr;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::mpsc::SyncSender;

    type IoConnect = u32;
    type IoObject = u32;
    type IoNotificationPort = *mut c_void;
    type CfRunLoop = *mut c_void;
    type CfRunLoopSource = *mut c_void;
    type CfRunLoopMode = *const c_void;

    const IO_MESSAGE_CAN_SYSTEM_SLEEP: u32 = 0xe000_0270;
    const IO_MESSAGE_SYSTEM_WILL_SLEEP: u32 = 0xe000_0280;
    const IO_MESSAGE_SYSTEM_HAS_POWERED_ON: u32 = 0xe000_0300;

    struct CallbackContext {
        gate: Arc<PowerGate>,
        connection: AtomicU32,
    }

    type PowerCallback = unsafe extern "C" fn(*mut c_void, u32, u32, *mut c_void);

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IORegisterForSystemPower(
            refcon: *mut c_void,
            port: *mut IoNotificationPort,
            callback: Option<PowerCallback>,
            notifier: *mut IoObject,
        ) -> IoConnect;
        fn IOAllowPowerChange(connection: IoConnect, notification_id: isize) -> i32;
        fn IODeregisterForSystemPower(notifier: *mut IoObject) -> i32;
        fn IONotificationPortGetRunLoopSource(port: IoNotificationPort) -> CfRunLoopSource;
        fn IONotificationPortDestroy(port: IoNotificationPort);
        fn IOServiceClose(connection: IoConnect) -> i32;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFRunLoopDefaultMode: CfRunLoopMode;
        fn CFRunLoopGetCurrent() -> CfRunLoop;
        fn CFRunLoopAddSource(run_loop: CfRunLoop, source: CfRunLoopSource, mode: CfRunLoopMode);
        fn CFRunLoopRun();
    }

    pub fn run_power_notification_loop(gate: Arc<PowerGate>, registered: SyncSender<Result<()>>) {
        let context = Box::new(CallbackContext {
            gate,
            connection: AtomicU32::new(0),
        });
        let context = Box::into_raw(context);
        let mut port = ptr::null_mut();
        let mut notifier = 0;
        let connection = unsafe {
            IORegisterForSystemPower(
                context.cast(),
                &mut port,
                Some(power_callback),
                &mut notifier,
            )
        };
        if connection == 0 {
            unsafe { drop(Box::from_raw(context)) };
            let _ = registered.send(Err(anyhow!("failed to register for system power events")));
            return;
        }
        unsafe { &*context }
            .connection
            .store(connection, Ordering::Release);
        let source = unsafe { IONotificationPortGetRunLoopSource(port) };
        let run_loop = unsafe { CFRunLoopGetCurrent() };
        unsafe { CFRunLoopAddSource(run_loop, source, kCFRunLoopDefaultMode) };
        if registered.send(Ok(())).is_err() {
            cleanup(connection, &mut notifier, port, context);
            return;
        }

        unsafe { CFRunLoopRun() };
        cleanup(connection, &mut notifier, port, context);
    }

    unsafe extern "C" fn power_callback(
        refcon: *mut c_void,
        _service: u32,
        message_type: u32,
        message_argument: *mut c_void,
    ) {
        let context = unsafe { &*(refcon as *const CallbackContext) };
        match message_type {
            IO_MESSAGE_CAN_SYSTEM_SLEEP => allow_power_change(context, message_argument),
            IO_MESSAGE_SYSTEM_WILL_SLEEP => {
                context.gate.handle(PowerEvent::WillSleep);
                allow_power_change(context, message_argument);
            }
            IO_MESSAGE_SYSTEM_HAS_POWERED_ON => {
                context.gate.handle(PowerEvent::DidWake);
            }
            _ => {}
        }
    }

    fn allow_power_change(context: &CallbackContext, message_argument: *mut c_void) {
        let connection = context.connection.load(Ordering::Acquire);
        unsafe {
            IOAllowPowerChange(connection, message_argument as isize);
        }
    }

    fn cleanup(
        connection: IoConnect,
        notifier: &mut IoObject,
        port: IoNotificationPort,
        context: *mut CallbackContext,
    ) {
        unsafe {
            IODeregisterForSystemPower(notifier);
            IONotificationPortDestroy(port);
            IOServiceClose(connection);
            drop(Box::from_raw(context));
        }
    }
}
