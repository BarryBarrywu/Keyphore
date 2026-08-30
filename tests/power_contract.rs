#[cfg(target_os = "macos")]
use keyphore::power::SystemPowerMonitor;
use keyphore::power::{PowerEvent, PowerGate};
use std::sync::Arc;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

#[test]
fn sleep_blocks_keyboard_access_until_wake() {
    let gate = PowerGate::default();

    assert!(gate.begin_hid_access().is_some());

    gate.handle(PowerEvent::WillSleep);
    assert!(gate.begin_hid_access().is_none());

    gate.handle(PowerEvent::DidWake);
    assert!(gate.begin_hid_access().is_some());
}

#[test]
fn sleep_waits_for_an_active_keyboard_operation_before_closing_the_gate() {
    let gate = Arc::new(PowerGate::default());
    let access = gate.begin_hid_access().unwrap();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (closed_tx, closed_rx) = mpsc::channel();
    let sleeping_gate = Arc::clone(&gate);
    let sleeper = thread::spawn(move || {
        ready_tx.send(()).unwrap();
        sleeping_gate.handle(PowerEvent::WillSleep);
        closed_tx.send(()).unwrap();
    });

    ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(closed_rx.recv_timeout(Duration::from_millis(50)).is_err());
    drop(access);

    closed_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    sleeper.join().unwrap();
    assert!(gate.begin_hid_access().is_none());
}

#[test]
fn a_sleep_wake_cycle_invalidates_the_existing_keyboard_connection() {
    let gate = PowerGate::default();
    let connected_generation = gate.generation();

    gate.handle(PowerEvent::WillSleep);
    gate.handle(PowerEvent::DidWake);

    assert_ne!(gate.generation(), connected_generation);
    assert!(gate.begin_hid_access_for(connected_generation).is_none());
}

#[cfg(target_os = "macos")]
#[test]
fn companion_can_register_for_macos_sleep_and_wake_events() {
    SystemPowerMonitor::register().unwrap();
}
