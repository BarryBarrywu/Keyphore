use std::io::{self, Read};
use std::path::PathBuf;
use std::{env, thread, time::Duration};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use nuphy_codex::companion::{Companion, VerifiedNuPhyIoAdapter};
use nuphy_codex::hid::discover_air65_v3;
use nuphy_codex::hook::handle_user_prompt_submit;
use nuphy_codex::nuphyio::{exercise_main_backlight, generate_session_challenge};
use nuphy_codex::status::DurableStatusStore;

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
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Diagnose { exercise } => diagnose(exercise),
        Command::Hook { status } => run_hook(status),
        Command::Companion { status, once } => run_companion(status, once),
    }
}

fn run_hook(status: Option<PathBuf>) -> Result<()> {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .context("failed to read Hook event from stdin")?;
    handle_user_prompt_submit(
        &input,
        &DurableStatusStore::new(status.unwrap_or_else(default_status_path)),
        Duration::from_millis(100),
    )
}

fn run_companion(status: Option<PathBuf>, once: bool) -> Result<()> {
    let store = DurableStatusStore::new(status.unwrap_or_else(default_status_path));
    let mut keyboard = discover_air65_v3()?;
    let mut adapter = VerifiedNuPhyIoAdapter::new(&mut keyboard.transport);
    let mut companion = Companion::default();
    loop {
        companion.sync(&store, &mut adapter)?;
        if once {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
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
