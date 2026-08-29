use std::fs;
use std::io::{self, Read};
use std::path::PathBuf;
use std::{
    env, thread,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use nuphy_codex::companion::{
    Companion, HealthAwareNuPhyIoAdapter, LightingCommand, VerifiedNuPhyIoAdapter,
};
use nuphy_codex::hid::discover_air65_v3;
use nuphy_codex::hook::handle_codex_event_at;
use nuphy_codex::lifecycle::PluginLifecycle;
use nuphy_codex::nuphyio::{AcceptanceSignal, exercise_main_backlight, generate_session_challenge};
use nuphy_codex::status::{DurableStatusStore, Timestamp};
use serde::{Deserialize, Serialize};

const HARDWARE_HEALTH_MAX_AGE: Duration = Duration::from_secs(3);

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
enum HardwareHealth {
    Healthy,
    Unavailable,
}

impl HardwareHealth {
    fn fields(self) -> (&'static str, &'static str, &'static str) {
        match self {
            Self::Healthy => ("air65-v3", "wired-usb", "healthy"),
            Self::Unavailable => ("unavailable", "unavailable", "unavailable"),
        }
    }
}

#[derive(Parser)]
#[command(name = "nuphy-codex", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Discover the verified Air65 V3 over wired USB.
    ///
    /// No lighting report is sent unless --exercise is provided.
    Diagnose {
        /// Apply execution, attention, completion, and signal-off to the main backlight.
        #[arg(long)]
        exercise: bool,
    },
    /// Report privacy-safe Plugin, companion, status, and hardware health.
    Diagnostics,
    /// Persist a privacy-allowlisted Codex lifecycle event without opening the keyboard.
    Hook {
        /// Durable-status file shared with the companion.
        #[arg(long, env = "NUPHY_CODEX_STATUS_PATH")]
        status: Option<PathBuf>,
    },
    /// Read durable status and apply it through the verified Air65 V3 adapter.
    Companion {
        /// Durable-status file shared with the Hook owner.
        #[arg(long, env = "NUPHY_CODEX_STATUS_PATH")]
        status: Option<PathBuf>,
        /// Apply the current durable state once and exit.
        #[arg(long)]
        once: bool,
    },
    /// Install, validate, update, or remove the Plugin lifecycle.
    Lifecycle {
        #[command(subcommand)]
        command: LifecycleCommand,
    },
}

#[derive(Subcommand)]
enum LifecycleCommand {
    /// Install or repair the companion and record this Plugin's ownership.
    Install {
        #[arg(long)]
        plugin_root: PathBuf,
        #[arg(long)]
        plugin_id: String,
    },
    /// Replace this Plugin's release unit while preserving durable status.
    Update {
        #[arg(long)]
        plugin_root: PathBuf,
        #[arg(long)]
        plugin_id: String,
    },
    /// Validate the installed lifecycle and its health surfaces.
    Validate,
    /// Stop the companion and remove only this Plugin and its managed state.
    Uninstall,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Diagnose { exercise } => diagnose(exercise),
        Command::Diagnostics => print_lifecycle_validation(&PluginLifecycle::from_environment()?),
        Command::Hook { status } => run_hook(status),
        Command::Companion { status, once } => run_companion(status, once),
        Command::Lifecycle { command } => run_lifecycle(command),
    }
}

fn run_lifecycle(command: LifecycleCommand) -> Result<()> {
    let lifecycle = PluginLifecycle::from_environment()?;
    match command {
        LifecycleCommand::Install {
            plugin_root,
            plugin_id,
        } => {
            lifecycle.install(&plugin_root, &plugin_id)?;
            println!("lifecycle=installed");
            println!("hook_trust_review_required=true");
            println!("codex_reload_required=true");
        }
        LifecycleCommand::Update {
            plugin_root,
            plugin_id,
        } => {
            lifecycle.update(&plugin_root, &plugin_id)?;
            println!("lifecycle=updated");
            println!("hook_trust_review_required=true");
            println!("codex_reload_required=true");
        }
        LifecycleCommand::Validate => {
            print_lifecycle_validation(&lifecycle)?;
        }
        LifecycleCommand::Uninstall => {
            lifecycle.uninstall()?;
            println!("lifecycle=removed");
            println!("codex_reload_required=true");
        }
    }
    Ok(())
}

fn print_lifecycle_validation(lifecycle: &PluginLifecycle) -> Result<()> {
    let Some((plugin_id, plugin_root)) = lifecycle.active_plugin()? else {
        println!("hook_ownership=not-installed");
        println!("durable_status=not-installed");
        println!("companion=not-installed");
        println!("keyboard_discovery=unavailable");
        println!("protocol_health=unavailable");
        println!("verified_transport=unavailable");
        println!("aggregate_state=unavailable");
        return Ok(());
    };
    nuphy_codex::lifecycle::validate_plugin_bundle(&plugin_root)?;
    println!(
        "hook_ownership={}",
        if lifecycle.plugin_is_enabled(&plugin_id)? {
            "owned"
        } else {
            "inactive"
        }
    );
    println!("plugin_id={plugin_id}");
    let companion_status = lifecycle.companion_status()?;
    println!("companion={companion_status}");
    let store = DurableStatusStore::new(lifecycle.data_dir().join("status.json"));
    let status = store.load()?;
    println!("durable_status=healthy");
    let aggregate = nuphy_codex::status_core::StatusCore::reduce_at(&status, Timestamp::now());
    println!("aggregate_state={aggregate:?}");
    if companion_status == "running" {
        let health =
            read_recent_hardware_health(&lifecycle.data_dir().join("hardware-health.json"))
                .unwrap_or(HardwareHealth::Unavailable);
        print_hardware_health(health);
        return Ok(());
    }
    match discover_air65_v3() {
        Ok(mut keyboard) => {
            println!("keyboard_discovery=air65-v3");
            println!("verified_transport=wired-usb");
            let protocol_health = VerifiedNuPhyIoAdapter::new(&mut keyboard.transport)
                .displays(LightingCommand::from_aggregate(aggregate))
                .map(|_| "healthy")
                .unwrap_or("unhealthy");
            println!("protocol_health={protocol_health}");
        }
        Err(_) => {
            print_hardware_health(HardwareHealth::Unavailable);
        }
    }
    Ok(())
}

fn print_hardware_health(health: HardwareHealth) {
    let (keyboard, transport, protocol) = health.fields();
    println!("keyboard_discovery={keyboard}");
    println!("verified_transport={transport}");
    println!("protocol_health={protocol}");
}

fn run_hook(status: Option<PathBuf>) -> Result<()> {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .context("failed to read Hook event from stdin")?;
    handle_codex_event_at(
        &input,
        &DurableStatusStore::new(status.unwrap_or_else(default_status_path)),
        Duration::from_millis(100),
        Timestamp::now(),
    )
}

fn run_companion(status: Option<PathBuf>, once: bool) -> Result<()> {
    let status_path = status.unwrap_or_else(default_status_path);
    let health_path = status_path.with_file_name("hardware-health.json");
    let store = DurableStatusStore::new(status_path);
    let mut companion = Companion::default();
    if once {
        let mut keyboard = discover_air65_v3()?;
        let result = companion.device_reconnected(
            &store,
            &mut VerifiedNuPhyIoAdapter::new(&mut keyboard.transport),
        );
        write_hardware_health(
            &health_path,
            if result.is_ok() {
                HardwareHealth::Healthy
            } else {
                HardwareHealth::Unavailable
            },
        )?;
        return result;
    }

    loop {
        let mut keyboard = match discover_air65_v3() {
            Ok(keyboard) => keyboard,
            Err(error) => {
                write_hardware_health(&health_path, HardwareHealth::Unavailable)?;
                eprintln!("waiting for verified Air65 V3: {error:#}");
                thread::sleep(Duration::from_secs(1));
                continue;
            }
        };
        let mut adapter = VerifiedNuPhyIoAdapter::new(&mut keyboard.transport);
        if let Err(error) = companion.device_reconnected(&store, &mut adapter) {
            write_hardware_health(&health_path, HardwareHealth::Unavailable)?;
            eprintln!("Air65 V3 connection lost while replaying status: {error:#}");
            thread::sleep(Duration::from_secs(1));
            continue;
        }
        write_hardware_health(&health_path, HardwareHealth::Healthy)?;
        let mut last_health_check = Instant::now();
        loop {
            thread::sleep(Duration::from_millis(100));
            if let Err(error) = companion.sync(&store, &mut adapter) {
                write_hardware_health(&health_path, HardwareHealth::Unavailable)?;
                eprintln!("Air65 V3 connection lost while applying status: {error:#}");
                break;
            }
            if last_health_check.elapsed() >= Duration::from_secs(1) {
                if let Err(error) = companion.health_check(&store, &mut adapter) {
                    write_hardware_health(&health_path, HardwareHealth::Unavailable)?;
                    eprintln!("Air65 V3 health check failed: {error:#}");
                    break;
                }
                write_hardware_health(&health_path, HardwareHealth::Healthy)?;
                last_health_check = Instant::now();
            }
        }
    }
}

fn write_hardware_health(path: &std::path::Path, health: HardwareHealth) -> Result<()> {
    let replacement = path.with_file_name(format!(".hardware-health.{}.tmp", std::process::id()));
    fs::write(&replacement, serde_json::to_vec(&health)?)
        .context("failed to write hardware-health replacement")?;
    fs::rename(replacement, path).context("failed to replace hardware health")
}

fn read_recent_hardware_health(path: &std::path::Path) -> Option<HardwareHealth> {
    let metadata = fs::metadata(path).ok()?;
    if metadata.modified().ok()?.elapsed().ok()? > HARDWARE_HEALTH_MAX_AGE {
        return None;
    }
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

fn default_status_path() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Library/Application Support/NuPhy Codex/status.json")
}

fn diagnose(exercise: bool) -> Result<()> {
    if PluginLifecycle::from_environment()?.companion_status()? == "running" {
        bail!("stop the installed companion before diagnosing the keyboard");
    }
    let mut keyboard = discover_air65_v3()?;
    println!(
        "supported device: NuPhy {} (USB {:04x}:{:04x}, interface {}, usage {:04x}:{:04x})",
        keyboard.descriptor.product,
        keyboard.descriptor.vendor_id,
        keyboard.descriptor.product_id,
        keyboard.descriptor.interface_number,
        keyboard.descriptor.usage_page,
        keyboard.descriptor.usage,
    );

    if !exercise {
        println!("discovery only: no lighting report was sent");
        return Ok(());
    }

    let evidence = exercise_main_backlight(
        &mut keyboard.transport,
        generate_session_challenge(),
        |signal| {
            let (description, seconds) = match signal {
                AcceptanceSignal::Execution => ("blue execution signal", 3),
                AcceptanceSignal::Attention => ("orange attention signal", 3),
                AcceptanceSignal::Completion => ("green completion", 5),
            };
            println!("{description} verified by readback; observing for {seconds} seconds");
            thread::sleep(Duration::from_secs(seconds));
        },
    )?;
    println!(
        "signal-off verified; rhythm light bar unchanged ({:02x?})",
        evidence.rhythm_after_off
    );
    Ok(())
}
