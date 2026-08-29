use std::io::{self, Read};
use std::path::PathBuf;
use std::{
    env, thread,
    time::{Duration, Instant},
};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use nuphy_codex::companion::{
    Companion, HealthAwareNuPhyIoAdapter, LightingCommand, VerifiedNuPhyIoAdapter,
};
use nuphy_codex::hid::discover_air65_v3;
use nuphy_codex::hook::handle_codex_event_at;
use nuphy_codex::lifecycle::PluginLifecycle;
use nuphy_codex::nuphyio::{exercise_main_backlight, generate_session_challenge};
use nuphy_codex::status::{DurableStatusStore, Timestamp};

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
        /// Apply a blue execution effect for three seconds, then turn the main backlight off.
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
        }
        LifecycleCommand::Update {
            plugin_root,
            plugin_id,
        } => {
            lifecycle.update(&plugin_root, &plugin_id)?;
            println!("lifecycle=updated");
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
    println!("companion={}", lifecycle.companion_status()?);
    let store = DurableStatusStore::new(lifecycle.data_dir().join("status.json"));
    let status = store.load()?;
    println!("durable_status=healthy");
    let aggregate = nuphy_codex::status_core::StatusCore::reduce_at(&status, Timestamp::now());
    println!("aggregate_state={aggregate:?}");
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
            println!("keyboard_discovery=unavailable");
            println!("verified_transport=unavailable");
            println!("protocol_health=unavailable");
        }
    }
    Ok(())
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
    let store = DurableStatusStore::new(status.unwrap_or_else(default_status_path));
    let mut companion = Companion::default();
    if once {
        let mut keyboard = discover_air65_v3()?;
        return companion.device_reconnected(
            &store,
            &mut VerifiedNuPhyIoAdapter::new(&mut keyboard.transport),
        );
    }

    loop {
        let mut keyboard = match discover_air65_v3() {
            Ok(keyboard) => keyboard,
            Err(error) => {
                eprintln!("waiting for verified Air65 V3: {error:#}");
                thread::sleep(Duration::from_secs(1));
                continue;
            }
        };
        let mut adapter = VerifiedNuPhyIoAdapter::new(&mut keyboard.transport);
        if let Err(error) = companion.device_reconnected(&store, &mut adapter) {
            eprintln!("Air65 V3 connection lost while replaying status: {error:#}");
            thread::sleep(Duration::from_secs(1));
            continue;
        }
        let mut last_health_check = Instant::now();
        loop {
            thread::sleep(Duration::from_millis(100));
            if let Err(error) = companion.sync(&store, &mut adapter) {
                eprintln!("Air65 V3 connection lost while applying status: {error:#}");
                break;
            }
            if last_health_check.elapsed() >= Duration::from_secs(1) {
                if let Err(error) = companion.health_check(&store, &mut adapter) {
                    eprintln!("Air65 V3 health check failed: {error:#}");
                    break;
                }
                last_health_check = Instant::now();
            }
        }
    }
}

fn default_status_path() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Library/Application Support/NuPhy Codex/status.json")
}

fn diagnose(exercise: bool) -> Result<()> {
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
        || {
            println!("blue execution effect verified by readback; observing for 3 seconds");
            thread::sleep(Duration::from_secs(3));
        },
    )?;
    println!(
        "signal-off verified; rhythm light bar unchanged ({:02x?})",
        evidence.rhythm_after_off
    );
    Ok(())
}
